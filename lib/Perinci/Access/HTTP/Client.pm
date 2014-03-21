package Perinci::Access::HTTP::Client;

use 5.010001;
use strict;
use warnings;
use experimental 'smartmatch';
use Log::Any '$log';

use Scalar::Util qw(blessed);

use parent qw(Perinci::Access::Base);

# VERSION

my @logging_methods = Log::Any->logging_methods();

sub new {
    my $class = shift;

    my $self = $class->SUPER::new(@_);

    # attributes
    $self->{retries}         //= 2;
    $self->{retry_delay}     //= 3;
    $self->{lwp_implementor} //= undef;
    unless (defined $self->{log_level}) {
        $self->{log_level} =
            $ENV{TRACE} ? 6 :
                $ENV{DEBUG} ? 5 :
                    $ENV{VERBOSE} ? 4 :
                        $ENV{QUIET} ? 2 :
                            0;
    }
    $self->{log_callback}    //= undef;
    $self->{user}            //= $ENV{PERINCI_HTTP_USER};
    $self->{password}        //= $ENV{PERINCI_HTTP_PASSWORD};

    $self;
}

# for older Perinci::Access::Base 0.28-, to remove later
sub _init {}

sub request {
    my ($self, $action, $server_url, $extra) = @_;
    $log->tracef(
        "=> %s\::request(action=%s, server_url=%s, extra=%s)",
        __PACKAGE__, $action, $server_url, $extra);
    return [400, "Please specify server_url"] unless $server_url;
    my $rreq = { action=>$action,
                 ua=>"Perinci/".($Perinci::Access::HTTP::Client::VERSION//"?"),
                 %{$extra // {}} };
    my $res = $self->check_request($rreq);
    return $res if $res;

    state $json = do {
        require JSON;
        JSON->new->allow_nonref;
    };

    state $ua;
    state $callback = sub {
        my ($resp, $ua, $h, $data) = @_;

        # we collect HTTP response body into __buffer first. if __mark_log is
        # set then we need to separate each log message and response part.
        # otherwise, everything just needs to go to __body.

        #$log->tracef("got resp: %s (%d bytes)", $data, length($data));
        #say sprintf("D:got resp: %s (%d bytes)", $data, length($data));

        if ($ua->{__log_level}) {
            $ua->{__buffer} .= $data;
            if ($ua->{__buffer} =~ /\A([lr])(\d+) /) {
                my ($chtype, $chlen) = ($1, $2);
                # not enough data yet
                my $hlen = 1+length($chlen)+1;
                return 1 unless length($ua->{__buffer}) >= $hlen + $chlen;
                my $chdata = substr($ua->{__buffer}, $hlen, $chlen);
                substr($ua->{__buffer}, 0, $hlen+$chlen) = "";
                if ($chtype eq 'l') {
                    if ($self->{log_callback}) {
                        $self->{log_callback}->($chdata);
                    } else {
                        $chdata =~ s/^\[(\w+)\]//;
                        my $method = $1;
                        $method = "error" unless $method ~~ @logging_methods;
                        $log->$method("[$server_url] $chdata");
                    }
                    return 1;
                } elsif ($chtype eq 'r') {
                    $ua->{__body} .= $chdata;
                } else {
                    $ua->{__body} = "[500,\"Unknown chunk type $chtype".
                        "try updating ${\(__PACKAGE__)} version\"]";
                    return 0;
                }
            } else {
                $ua->{__body} = "[500,\"Invalid response from server,".
                    " server is probably using older version of ".
                        "Riap::HTTP server library\"]";
                return 0;
            }
        } else {
            $ua->{__body} .= $data;
        }
    };

    if (!$ua) {
        require LWP::UserAgent;
        $ua = LWP::UserAgent->new;
        $ua->env_proxy;
        $ua->set_my_handler(
            "request_send", sub {
                my ($req, $ua, $h) = @_;
                $ua->{__buffer} = "";
                $ua->{__body} = "";
            });
        $ua->set_my_handler(
            "response_header", sub {
                my ($resp, $ua, $h) = @_;
                $ua->{__log_level} = 0 unless $resp->header('x-riap-logging');
            });
        $ua->set_my_handler(
            "response_data", $callback);
    }

    if (defined $self->{user}) {
        require URI;
        my $suri = URI->new($server_url);
        my $host = $suri->host;
        my $port = $suri->port;
        $ua->credentials(
            "$host:$port",
            $self->{realm} // "restricted area",
            $self->{user},
            $self->{password},
        );
    }

    my $http_req = HTTP::Request->new(POST => $server_url);
    for (keys %$rreq) {
        next if /\A(?:args|fmt|loglevel|_.*)\z/;
        my $hk = "x-riap-$_";
        my $hv = $rreq->{$_};
        if (!defined($hv) || ref($hv)) {
            $hk = "$hk-j-";
            $hv = $json->encode($hv);
        }
        $http_req->header($hk => $hv);
    }
    $ua->{__log_level} = $self->{log_level};
    $http_req->header('x-riap-loglevel' => $ua->{__log_level});
    $http_req->header('x-riap-fmt'      => 'json');

    my %args;
    if ($rreq->{args}) {
        for (keys %{$rreq->{args}}) {
            $args{$_} = $rreq->{args}{$_};
        }
    }
    my $args_s = $json->encode(\%args);
    $http_req->header('Content-Type' => 'application/json');
    $http_req->header('Content-Length' => length($args_s));
    $http_req->content($args_s);

    #use Data::Dump; dd $http_req;

    my $attempts = 0;
    my $do_retry;
    my $http_res;
    while (1) {
        $do_retry = 0;

        my $old_imp;
        if ($self->{lwp_implementor}) {
            my $imp = $self->{lwp_implementor};
            $imp =~ s!::!/!g; $imp .= ".pm";
            $old_imp = LWP::Protocol::implementor("http");
            eval "require $imp" or
                return [500, "Can't load $self->{lwp_implementor}: $@"];
            LWP::Protocol::implementor("http", $imp);
        }

        eval { $http_res = $ua->request($http_req) };
        my $eval_err = $@;

        if ($old_imp) {
            LWP::Protocol::implementor("http", $old_imp);
        }

        return [500, "Client died: $eval_err"] if $eval_err;

        if ($http_res->code >= 500) {
            $log->warnf("Network failure (%d - %s), retrying ...",
                        $http_res->code, $http_res->message);
            $do_retry++;
        }

        if ($do_retry && $attempts++ < $self->{retries}) {
            sleep $self->{retry_delay};
        } else {
            last;
        }
    }

    return [500, "Network failure: ".$http_res->code." - ".$http_res->message]
        unless $http_res->is_success;

    # empty __buffer
    $callback->($http_res, $ua, undef, "") if length($ua->{__buffer});

    return [500, "Empty response from server (1)"]
        if !length($http_res->content);
    return [500, "Empty response from server (2)"]
        unless length($ua->{__body});

    eval {
        #say "D:body=$ua->{__body}";
        $log->tracef("body: %s", $ua->{__body});
        $res = $json->decode($ua->{__body});
    };
    my $eval_err = $@;
    return [500, "Invalid JSON from server: $eval_err"] if $eval_err;

    #use Data::Dump; dd $res;
    $res;
}

sub parse_url {
    require URI::Split;

    my ($self, $uri) = @_;
    die "Please specify url" unless $uri;

    my $res = $self->request(info => $uri);
    die "Can't 'info' on $uri: $res->[0] - $res->[1]" unless $res->[0] == 200;

    my $resuri = $res->[2]{uri};
    my ($sch, $auth, $path) = URI::Split::uri_split($resuri);
    $sch //= "pl";

    {proto=>$sch, path=>$path};
}

1;
# ABSTRACT: Riap::HTTP client

=for Pod::Coverage ^action_.+

=cut

=head1 SYNOPSIS

 use Perinci::Access::HTTP::Client;
 my $pa = Perinci::Access::HTTP::Client->new;

 ## perform Riap requests

 # list all functions in package
 my $res = $pa->request(list => 'http://localhost:5000/api/',
                        {uri=>'/Some/Module/', type=>'function'});
 # -> [200, "OK", ['/Some/Module/mult2', '/Some/Module/mult2']]

 # call function
 $res = $pa->request(call => 'http://localhost:5000/api/',
                     {uri=>'/Some/Module/mult2', args=>{a=>2, b=>3}});
 # -> [200, "OK", 6]

 # get function metadata
 $res = $pa->request(meta => 'http://localhost:5000/api/',
                     {uri=>'/Foo/Bar/multn'});
 # -> [200, "OK", {v=>1.1, summary=>'Multiple many numbers', ...}]

 # pass HTTP credentials
 my $pa = Perinci::Access::HTTP::Client->new(user => 'admin', password=>'123');
 my $res = $pa->request(call => '...', {...});
 # -> [200, "OK", 'result']

 ## parse server URL
 $res = $pa->parse_url("https://cpanlists.org/api/"); # {proto=>"https", path=>"/App/cpanlists/Server/"}


=head1 ATTRIBUTES

=over

=item * realm => STR

For HTTP basic authentication. Defaults to "restricted area" (this is the
default realm used by L<Plack::Middleware::Auth::Basic>).

=item * user => STR

For HTTP basic authentication. Default will be taken from environment
C<PERINCI_HTTP_USER>.

=item * password => STR

For HTTP basic authentication. Default will be taken from environment
C<PERINCI_HTTP_PASSWORD>.

=back


=head1 DESCRIPTION

This class implements L<Riap::HTTP> client.

This class uses L<Log::Any> for logging.


=head1 METHODS

=head2 PKG->new(%attrs) => OBJ

Instantiate object. Known attributes:

=over

=item * retries => INT (default 2)

Number of retries to do on network failure. Setting it to 0 will disable
retries.

=item * retry_delay => INT (default 3)

Number of seconds to wait between retries.

=item * lwp_implementor => STR

If specified, use this class for http LWP::Protocol::implementor(). For example,
to access Unix socket server instead of a normal TCP one, set this to
'LWP::Protocol::http::SocketUnix'.

=item * log_level => INT (default 0 or from environment)

Will be fed into Riap request key 'loglevel' (if >0). Note that some servers
might forbid setting log level.

If TRACE environment variable is true, default log_level will be set to 6. If
DEBUG, 5. If VERBOSE, 4. If quiet, 1. Else 0.

=item * log_callback => CODE

Pass log messages from the server to this subroutine. If not specified, log
messages will be "rethrown" into Log::Any logging methods (e.g. $log->warn(),
$log->debug(), etc).

=back

=head2 $pa->request($action => $server_url, \%extra_keys) => $res

Send Riap request to $server_url. Note that $server_url is the HTTP URL of Riap
server. You will need to specify code entity URI via C<uri> key in %extra_keys.

C<%extra_keys> is optional and contains additional Riap request keys (except
 C<action>, which is taken from C<$action>).

=head2 $pa->parse_url($server_url) => HASH


=head1 ENVIRONMENT

C<PERINCI_HTTP_USER>.

C<PERINCI_HTTP_PASSWORD>.


=head1 FAQ

=head2 How do I connect to an HTTPS server without a "real" SSL certificate?

Set environment variable C<PERL_LWP_SSL_VERIFY_HOSTNAME> to 0. See L<LWP> for
more details.


=head1 TODO

=over

=item * attr: hook/handler to pass to $ua

=item * attr: use custom $ua object

=back


=head1 SEE ALSO

L<Perinci::Access::HTTP::Server>

L<Riap>, L<Rinci>

=cut

package UR::Service::WebServer;

use strict;
use warnings;

use UR;
use UR::Service::WebServer::Server;
use IO::File;

class UR::Service::WebServer {
    has => [
        host => { is => 'String',
                    default_value => 'localhost',
                    doc => 'IP address to listen on' },
        port => { is => 'Integer',
                    default_value => undef,
                    doc => 'TCP port to listen on' },
    ],
    has_optional => [
        server  => { is => 'HTTP::Server::PSGI', calculate_from => ['__host','__port'], is_constant => 1,
                    calculate => q(
                        return UR::Service::WebServer::Server->new(
                            host => $__host,
                            port => $__port,
                            timeout => $self->timeout,
                            server_ready => sub { $self->_announce() },
                        );
                    ), },
        timeout => { is => 'Integer',
                        default_value => undef,
                        doc => 'Timeout for read and write events' },
        idle_timeout => { is => 'Integer', default_value => undef,
                        doc => 'Exit the event loop after being idle for this many seconds' },
        cb => { is => 'CODE', doc => 'callback for handling requests' },
    ],
};

# Override port and host so they can auto-fill when needed
sub _port_host_override {
    my $self = shift;
    my $methodname = shift;
    my $method = '__'.$methodname;
    my $socket_method = 'sock'.$methodname;
    if (@_) {
        if ($self->{server}) {
            die "Cannot change $methodname after it has created the listen socket";
        }
        $self->$method(@_);

    } else {
      #  if (!defined($self->$method) && !defined($self->{server})) {
        unless (defined $self->$method) {
            unless (defined $self->{server}) {
                # not connected yet - start the server's listen socket and get its port
                $self->server->setup_listener();
            }
            $self->$method( $self->server->listen_sock->$socket_method() );
        }
    }
    return $self->$method;
}

sub port {
    my $self = shift;
    $self->_port_host_override('port', @_);
}

sub host {
    my $self = shift;
    $self->_port_host_override('host', @_);
}


sub _announce {
    my $self = shift;

    my $sock = $self->server->listen_sock;
    $self->status_message(sprintf('Listening on http://%s:%d/', $sock->sockhost, $sock->sockport));
    return 1;
}

sub run {
    my $self = shift;

    my $cb = shift || $self->cb;

    my $timeout = $self->idle_timeout || 0;
    local $SIG{'ALRM'} = sub { die "alarm\n" };
    eval {
        alarm($timeout);
        $self->server->run($cb);
    };
    alarm(0);
    die $@ unless $@ eq "alarm\n";
}

my %mime_types = (
    'js'    => 'application/javascript',
    'html'  => 'text/html',
    'css'   => 'text/css',
    '*'     => 'text/plain',
);
sub _mime_type_for_filename {
    my($self, $pathname) = @_;
    my($ext) = ($pathname =~ m/\.(\w+)$/);
    $ext ||= '*';
    return $mime_types{$ext} || $mime_types{'*'};
}
sub _file_opener_for_directory {
    my($self, $dir) = @_;
    return sub {
        (my $pathname = shift) =~ s#/?\.\.##g;  # Remove .. - don't want them escaping the given directory tree
        return IO::File->new( join('/', $dir, $pathname), 'r');
    };
    
}
sub file_handler_for_directory {
    my($self, $dir) = @_;

    my $opener = $self->_file_opener_for_directory($dir);

    return sub {
        my($env, $pathname) = @_;

        my $fh = $opener->($pathname);
        unless($fh) {
            return [ 404, [ 'Content-Type' => 'text/plain'], ['Not Found']];
        }
        my $type = $self->_mime_type_for_filename($pathname);
        if ($env->{'psgi.streaming'}) {
            return [ 200, ['Content-Type' => $type], $fh];
        } else {
            local $/;
            my $buffer = <$fh>;
            return [ 200, ['Content-Type' => $type], [$buffer]];
        }
    };
}

sub delete {
    my $self = shift;
    $self->server->listen_sock->close();
    $self->{server} = undef;
    $self->SUPER::delete(@_);
}

1;

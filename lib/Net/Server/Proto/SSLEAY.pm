# -*- perl -*-
#
#  Net::Server::Proto::SSLEAY - Net::Server Protocol module
#
#  $Id$
#
#  Copyright (C) 2010
#
#    Paul Seamons
#    paul@seamons.com
#    http://seamons.com/
#
#  This package may be distributed under the terms of either the
#  GNU General Public License
#    or the
#  Perl Artistic License
#
#  All rights reserved.
#
################################################################

package Net::Server::Proto::SSLEAY;

use strict;
use vars qw($VERSION $AUTOLOAD @ISA);
use IO::Socket::INET;
use Tie::Handle;
use Fcntl ();
eval { require Net::SSLeay; };
$@ && warn "Module Net::SSLeay is required for SSLeay.";
BEGIN {
    # Net::SSLeay gets mad if we call these multiple times - the question is - who will call them multiple times?
    for my $sub (qw(load_error_strings SSLeay_add_ssl_algorithms ENGINE_load_builtin_engines ENGINE_register_all_complete randomize)) {
        Net::SSLeay->can($sub)->();
        eval 'no warnings "redefine"; sub Net::SSLeay::$sub () {}';
    }
}

$VERSION = $Net::Server::VERSION; # done until separated
@ISA = qw(IO::Socket::INET);

sub object {
    my $type  = shift;
    my $class = ref($type) || $type || __PACKAGE__;

    my ($default_host,$port,$server) = @_;
    my $prop = $server->{'server'};
    my $host;

    if ($port =~ m/^([\w\.\-\*\/]+):(\w+)$/) { # allow for things like "domain.com:80"
        ($host, $port) = ($1, $2);
    }
    elsif ($port =~ /^(\w+)$/) { # allow for things like "80"
        ($host, $port) = ($default_host, $1);
    }
    else {
        $server->fatal("Undeterminate port \"$port\" under ".__PACKAGE__);
    }

    # read any additional protocol specific arguments
    my @ssl_args = qw(
        SSL_server
        SSL_use_cert
        SSL_verify_mode
        SSL_key_file
        SSL_cert_file
        SSL_ca_path
        SSL_ca_file
        SSL_cipher_list
        SSL_passwd_cb
        SSL_max_getline_length
    );
    my %args;
    $args{$_} = \$prop->{$_} for @ssl_args;
    $server->configure(\%args);

    my $sock = $class->new;
    $sock->NS_host($host);
    $sock->NS_port($port);
    $sock->NS_proto('SSLeay');

    for my $key (@ssl_args) {
        my $val = defined($prop->{$key}) ? $prop->{$key} : $server->can($key) ? $server->$key($host, $port, 'SSLeay') : undef;
        $sock->$key($val);
    }

    return $sock;
}

sub log_connect {
    my $sock = shift;
    my $server = shift;
    my $host   = $sock->NS_host;
    my $port   = $sock->NS_port;
    my $proto  = $sock->NS_proto;
    $server->log(2,"Binding to $proto port $port on host $host\n");
}

###----------------------------------------------------------------###

sub connect { # connect the first time
    my $sock   = shift;
    my $server = shift;
    my $prop   = $server->{'server'};

    my $host  = $sock->NS_host;
    my $port  = $sock->NS_port;

    my %args;
    $args{'LocalPort'} = $port;                  # what port to bind on
    $args{'Proto'}     = 'tcp';                  # what procol to use
    $args{'LocalAddr'} = $host if $host !~ /\*/; # what local address (* is all)
    $args{'Listen'}    = $prop->{'listen'};      # how many connections for kernel to queue
    $args{'Reuse'}     = 1;                      # allow us to rebind the port on a restart

    my @keys = grep {/^SSL_/} keys %$prop;
    @args{@keys} = @{ $prop }{@keys};

    $sock->SUPER::configure(\%args) || $server->fatal("Can't connect to SSL port $port on $host [$!]");
    $server->fatal("Back sock [$!]!".caller()) if ! $sock;

    if ($port == 0 && ($port = $sock->sockport)) {
        $sock->NS_port($port);
        $server->log(2,"Bound to auto-assigned port $port");
    }

    $sock->bind_SSL($server);
}

sub reconnect { # connect on a sig -HUP
    my ($sock, $fd, $server) = @_;
    my $resp = $sock->fdopen( $fd, 'w' ) || $server->fatal("Error opening to file descriptor ($fd) [$!]");
    $sock->bind_SSL($server);
    return $resp;
}

sub bind_SSL {
    my ($sock, $server) = @_;
    my $ctx = Net::SSLeay::CTX_new();  $sock->SSLeay_check_fatal("SSLeay bind_SSL CTX_new");

    Net::SSLeay::CTX_set_options($ctx, Net::SSLeay::OP_ALL());  $sock->SSLeay_check_fatal("SSLeay bind_SSL CTX_set_options");

    # 0x1:  SSL_MODE_ENABLE_PARTIAL_WRITE
    # 0x10: SSL_MODE_RELEASE_BUFFERS (ignored before OpenSSL v1.0.0)
    Net::SSLeay::CTX_set_mode($ctx, 0x11);  $sock->SSLeay_check_fatal("SSLeay bind_SSL CTX_set_mode");

    # Load certificate. This will prompt for a password if necessary.
    my $file_key  = $sock->SSL_key_file  || die "SSLeay missing SSL_key_file.\n";
    my $file_cert = $sock->SSL_cert_file || die "SSLeay missing SSL_cert_file.\n";
    Net::SSLeay::CTX_use_RSAPrivateKey_file($ctx, $file_key,  Net::SSLeay::FILETYPE_PEM());  $sock->SSLeay_check_fatal("SSLeay bind_SSL CTX_use_RSAPrivateKey_file");
    Net::SSLeay::CTX_use_certificate_file(  $ctx, $file_cert, Net::SSLeay::FILETYPE_PEM());  $sock->SSLeay_check_fatal("SSLeay bind_SSL CTX_use_certificate_file");
    $sock->SSLeay_context($ctx);
}

sub close {
    my $sock = shift;
    if ($sock->SSLeay_is_client) {
        Net::SSLeay::free($sock->SSLeay);
    } else {
        Net::SSLeay::CTX_free($sock->SSLeay_context);
    }
    $sock->SSLeay_check_fatal("SSLeay close free");
    return $sock->SUPER::close(@_);
}

sub accept {
    my $sock = shift;
    my $client = $sock->SUPER::accept;
    if (defined $client) {
        $client->NS_proto($sock->NS_proto);
        $client->SSLeay_context($sock->SSLeay_context);
        $client->SSLeay_is_client(1);
    }

    return $client;
}

sub SSLeay {
    my $client = shift;

    if (! exists ${*$client}{'SSLeay'}) {
        die "SSLeay refusing to accept on non-client socket" if !$client->SSLeay_is_client;

        $client->autoflush(1);

        my $f = fcntl($client, Fcntl::F_GETFL(), 0)                || die "SSLeay - fcntl get: $!\n";
        fcntl($client, Fcntl::F_SETFL(), $f | Fcntl::O_NONBLOCK()) || die "SSLeay - fcntl set: $!\n";

        my $ssl = Net::SSLeay::new($client->SSLeay_context);  $client->SSLeay_check_fatal("SSLeay new");
        Net::SSLeay::set_fd($ssl, $client->fileno);           $client->SSLeay_check_fatal("SSLeay set_fd");
        Net::SSLeay::accept($ssl);                            $client->SSLeay_check_fatal("SSLeay accept");
        ${*$client}{'SSLeay'} = $ssl;
    }

    return ${*$client}{'SSLeay'};
}

sub SSLeay_check_fatal {
    my ($class, $msg) = @_;
    if (my $err = $class->SSLeay_check_error) {
        my ($file, $pkg, $line) = caller;
        die "$msg at $file line $line\n  ".join('  ', @$err);
    }
}

sub SSLeay_check_error {
    my $class = shift;
    my @err;
    while (my $n = Net::SSLeay::ERR_get_error()) {
        push @err, "$n. ". Net::SSLeay::ERR_error_string($n) ."\n";
    }
    return \@err if @err;
    return;
}


###----------------------------------------------------------------###

sub read_until {
    my ($client, $bytes, $end_qr) = @_;

    my $ssl = $client->SSLeay;
    my $content = ${*$client}{'SSLeay_buffer'};
    $content = '' if ! defined $content;
    my $ok = 0;
    $0 .= ' reading';
    OUTER: while (1) {
        if (!length($content)) {
        }
        elsif (defined($bytes) && length($content) >= $bytes) {
            ${*$client}{'SSLeay_buffer'} = substr($content, $bytes, length($content), '');
            $ok = 2;
            last;
        }
        elsif (defined($end_qr) && $content =~ m/$end_qr/g) {
            my $n = pos($content);
            ${*$client}{'SSLeay_buffer'} = substr($content, $n, length($content), '');
            $ok = 1;
            last;
        }

        vec(my $vec = '', $client->fileno, 1) = 1;
        select($vec, undef, undef, undef);

        my $n_empty = 0;
        while (1) {
            # 16384 is the maximum amount read() can return
            my $buf = Net::SSLeay::read($ssl, 16384); # read the most we can - continue reading until the buffer won't read any more
            last OUTER if $client->SSLeay_check_error;
            die "SSLeay read_until: $!\n" if ! defined($buf) && !$!{EAGAIN} && !$!{EINTR} && !$!{ENOBUFS};
            last if ! defined($buf);
            last OUTER if !length($buf) && $n_empty++;
            $content .= $buf;
        }
    }
    return ($ok, $content);
}

sub read {
    my ($client, $buf, $size, $offset) = @_;
    my ($ok, $read) = $client->read_until($size);
    substr($_[1], $offset || 0, defined($buf) ? length($buf) : 0, $read);
    return length $read;
}

sub getline {
    my $client = shift;
    my ($ok, $line) = $client->read_until($client->SSL_max_getline_length || 2_000_000, $/);
    return $line;
}

sub getlines {
    my $client = shift;
    my @lines;
    while (1) {
        my ($ok, $line) = $client->read_until($client->SSL_max_getline_length || 2_000_000, $/);
        push @lines, $line;
        last if $ok != 1;
    }
    return @lines;
}

sub print {
    my $client = shift;
    $client->write(@_ == 1 ? $_[0] : join('', @_));
}

sub printf {
    my $client = shift;
    $client->print(sprintf @_);
}

sub say {
    my $client = shift;
    $client->print(@_, "\n");
}

sub write {
    my $client = shift;
    my $buf    = shift;
    $buf = substr($buf, $_[1] || 0, $_[0]) if @_;
    my $ssl    = $client->SSLeay;
    $0 .= ' writing';
    while (length $buf) {
        vec(my $vec = '', $client->fileno, 1) = 1;
        select(undef, $vec, undef, undef);

        my $write = Net::SSLeay::write($ssl, $buf);
        return 0 if $client->SSLeay_check_error;
        die "SSLeay write: $!\n" if $write == -1 && !$!{EAGAIN} && !$!{EINTR} && !$!{ENOBUFS};
        substr($buf, 0, $write, "") if $write > 0;
    }
    return 1;
}

###----------------------------------------------------------------###

sub hup_string {
    my $sock = shift;
    return join "|", map{$sock->$_()} qw(NS_host NS_port NS_proto);
}

sub show {
    my $sock = shift;
    my $t = "Ref = \"" .ref($sock) . "\"\n";
    foreach my $prop ( qw(NS_proto NS_port NS_host SSLeay_context SSLeay_is_client) ){
        $t .= "  $prop = \"" .$sock->$prop()."\"\n";
    }
    return $t;
}

sub AUTOLOAD {
    my $sock = shift;
    my $prop = $AUTOLOAD =~ /::([^:]+)$/ ? $1 : die "Missing property in AUTOLOAD.";
    die "Unknown method or property [$prop]"
        if $prop !~ /^(NS_proto|NS_port|NS_host|SSLeay_context|SSLeay_is_client|SSL_\w+)$/;

    no strict 'refs';
    *{__PACKAGE__."::${prop}"} = sub {
        my $sock = shift;
        if (@_) {
            ${*$sock}{$prop} = shift;
            return delete ${*$sock}{$prop} if ! defined ${*$sock}{$prop};
        } else {
            return ${*$sock}{$prop};
        }
    };
    return $sock->$prop(@_);
}

1;

=head1 NAME

Net::Server::Proto::SSLeay - Custom Net::Server SSL protocol handler based on Net::SSLeay directly.

=head1 SYNOPSIS

See L<Net::Server::Proto>.

=head1 DESCRIPTION

Experimental.  If anybody has any successes or ideas for
improvment under SSLeay, please email <paul@seamons.com>.

Protocol module for Net::Server.  This module implements a
secure socket layer over tcp (also known as SSL).
See L<Net::Server::Proto>.

=head1 PARAMETERS

=head1 BUGS

=head1 LICENCE

Distributed under the same terms as Net::Server

=cut

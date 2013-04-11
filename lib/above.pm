package above;

use strict;
use warnings;

use Cwd qw(cwd);
use File::Spec qw();

our $VERSION = '0.02';

sub import {
    my $package = shift;
    for (@_) {
        use_package($_);
    }
}

our %used_libs;
BEGIN {
    %used_libs = ($ENV{PERL_USED_ABOVE} ? (map { $_ => 1 } split(":", $ENV{PERL_USED_ABOVE})) : ());
    for my $path (keys %used_libs) {
        eval "use lib '$path';";
        die "Failed to use library path '$path' from the environment PERL_USED_ABOVE?: $@" if $@;
    }
};

sub _caller_use {
    my ($caller, $class) = @_;
    eval "package $caller; use $class";
    die $@ if $@;
}

sub use_package {
    my $class  = shift;
    my $caller = (caller(1))[0];
    my $module = File::Spec->join(split(/::/, $class)) . '.pm';

    ## paths already found in %used_above have
    ## higher priority than paths based on cwd
    for my $path (keys %used_libs) {
        if (-e File::Spec->join($path, $module)) {
            _caller_use($caller, $class);
            return;
        }
    }

    my @parts = File::Spec->splitdir(cwd());
    my $path;
    do {
        $path = File::Spec->join(@parts);
        pop @parts;
    } until (-e File::Spec->join($path, $module) || (@parts == 1 && $parts[0] eq ''));

    if (-d $path) {
        while ($path =~ s:/[^/]+/\.\./:/:) { 1 } # simplify
        unless ($used_libs{$path}) {
            print STDERR "Using libraries at $path\n" unless $ENV{PERL_ABOVE_QUIET} or $ENV{COMP_LINE};
            eval "use lib '$path';";
            die $@ if $@;
            $used_libs{$path} = 1;
            my $env_value = join(":", sort keys %used_libs);
            $ENV{PERL_USED_ABOVE} = $env_value;
        }
    }

    _caller_use($caller, $class);
};

1;

=pod

=head1 NAME

above - auto "use lib" when a module is in the tree of the PWD 

=head1 SYNOPSIS

use above "My::Module";

=head1 DESCRIPTION

Used by the command-line wrappers for Command modules which are developer tools.

Do NOT use this in modules, or user applications.

Uses a module as though the cwd and each of its parent directories were at the beginnig of @INC.
If found in that path, the parent directory is kept as though by "use lib".

=head1 EXAMPLES

# given
/home/me/perlsrc/My/Module.pm

# in    
/home/me/perlsrc/My/Module/Some/Path/

# in myapp.pl:
use above "My::Module";

# does this ..if run anywhere under /home/me/perlsrc: 
use lib '/home/me/perlsrc/'
use My::Module;

=head1 AUTHOR

Scott Smith

=cut


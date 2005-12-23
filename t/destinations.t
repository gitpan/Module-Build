#!/usr/bin/perl -w

use lib 't/lib';
use strict;

use Test::More tests => 92;


use File::Spec ();
my $common_pl = File::Spec->catfile( 't', 'common.pl' );
require $common_pl;


use Cwd ();
my $cwd = Cwd::cwd;
my $tmp = File::Spec->catdir( $cwd, 't', '_tmp' );

use DistGen;
my $dist = DistGen->new( dir => $tmp );
$dist->regen;

chdir( $dist->dirname ) or die "Can't chdir to '@{[$dist->dirname]}': $!";


use Config;
use File::Spec::Functions qw( catdir splitdir );

#########################

# We need to create a well defined environment to test install paths.
# We do this by setting up appropriate Config entries.

use Module::Build;
my @installstyle = qw(lib perl5);
my $mb = Module::Build->new_from_context(
  installdirs => 'site',
  config => {
    installstyle    => catdir(@installstyle),

    installprivlib  => catdir($tmp, @installstyle),
    installarchlib  => catdir($tmp, @installstyle,
			      @Config{qw(version archname)}),
    installbin      => catdir($tmp, 'bin'),
    installscript   => catdir($tmp, 'bin'),
    installman1dir  => catdir($tmp, 'man', 'man1'),
    installman3dir  => catdir($tmp, 'man', 'man3'),
    installhtml1dir => catdir($tmp, 'html'),
    installhtml3dir => catdir($tmp, 'html'),

    installsitelib      => catdir($tmp, 'site', @installstyle, 'site_perl'),
    installsitearch     => catdir($tmp, 'site', @installstyle, 'site_perl',
				  @Config{qw(version archname)}),
    installsitebin      => catdir($tmp, 'site', 'bin'),
    installsitescript   => catdir($tmp, 'site', 'bin'),
    installsiteman1dir  => catdir($tmp, 'site', 'man', 'man1'),
    installsiteman3dir  => catdir($tmp, 'site', 'man', 'man3'),
    installsitehtml1dir => catdir($tmp, 'site', 'html'),
    installsitehtml3dir => catdir($tmp, 'site', 'html'),
  }
);
isa_ok( $mb, 'Module::Build::Base' );

# Get us into a known state.
$mb->install_base(undef);
$mb->prefix(undef);


# Check that we install into the proper default locations.
{
    is( $mb->installdirs, 'site' );
    is( $mb->install_base, undef );
    is( $mb->prefix,       undef );

    test_install_destinations( $mb, {
      lib     => catdir($tmp, 'site', @installstyle, 'site_perl'),
      arch    => catdir($tmp, 'site', @installstyle, 'site_perl',
			@Config{qw(version archname)}),
      bin     => catdir($tmp, 'site', 'bin'),
      script  => catdir($tmp, 'site', 'bin'),
      bindoc  => catdir($tmp, 'site', 'man', 'man1'),
      libdoc  => catdir($tmp, 'site', 'man', 'man3'),
      binhtml => catdir($tmp, 'site', 'html'),
      libhtml => catdir($tmp, 'site', 'html'),
    });
}


# Is installdirs honored?
{
    $mb->installdirs('core');
    is( $mb->installdirs, 'core' );

    test_install_destinations( $mb, {
      lib     => catdir($tmp, @installstyle),
      arch    => catdir($tmp, @installstyle, @Config{qw(version archname)}),
      bin     => catdir($tmp, 'bin'),
      script  => catdir($tmp, 'bin'),
      bindoc  => catdir($tmp, 'man', 'man1'),
      libdoc  => catdir($tmp, 'man', 'man3'),
      binhtml => catdir($tmp, 'html'),
      libhtml => catdir($tmp, 'html'),
    });

    $mb->installdirs('site');
    is( $mb->installdirs, 'site' );
}


# Check install_base()
{
    my $install_base = catdir( 'foo', 'bar' );
    $mb->install_base( $install_base );

    is( $mb->prefix,       undef );
    is( $mb->install_base, $install_base );


    test_install_destinations( $mb, {
        lib     => catdir( $install_base, 'lib', 'perl5' ),
        arch    => catdir( $install_base, 'lib', 'perl5', $Config{archname} ),
        bin     => catdir( $install_base, 'bin' ),
        script  => catdir( $install_base, 'bin' ),
        bindoc  => catdir( $install_base, 'man', 'man1'),
        libdoc  => catdir( $install_base, 'man', 'man3' ),
        binhtml => catdir( $install_base, 'html' ),
        libhtml => catdir( $install_base, 'html' ),
    });
}


# Basic prefix test.  Ensure everything is under the prefix.
{
    $mb->install_base( undef );
    ok( !defined $mb->install_base );

    my $prefix = catdir( qw( some prefix ) );
    $mb->prefix( $prefix );
    is( $mb->{properties}{prefix}, $prefix );

    test_prefix($prefix, $mb->install_sets('site'));
}


# And now that prefix honors installdirs.
{
    $mb->installdirs('core');
    is( $mb->installdirs, 'core' );

    my $prefix = catdir( qw( some prefix ) );
    test_prefix($prefix);

    $mb->installdirs('site');
    is( $mb->installdirs, 'site' );
}


# Try a config setting which would result in installation locations outside
# the prefix.  Ensure it doesn't.
{
    # Get the prefix defaults
    my $defaults = $mb->prefix_relpaths('site');

    # Create a configuration involving weird paths that are outside of
    # the configured prefix.
    my @prefixes = (
                    [qw(foo bar)],
                    [qw(biz)],
                    [],
                   );

    my %test_config;
    foreach my $type (keys %$defaults) {
        my $prefix = shift @prefixes || [qw(foo bar)];
        $test_config{$type} = catdir(File::Spec->rootdir, @$prefix, 
                                     @{$defaults->{$type}});
    }

    # Poke at the innards of MB to change the default install locations.
    local $mb->install_sets->{site} = \%test_config;
    $mb->config(siteprefixexp => catdir(File::Spec->rootdir, 
					'wierd', 'prefix'));

    my $prefix = catdir('another', 'prefix');
    $mb->prefix($prefix);
    test_prefix($prefix, \%test_config);
}


# Check that we can use install_base after setting prefix.
{
    my $install_base = catdir( 'foo', 'bar' );
    $mb->install_base( $install_base );

    test_install_destinations( $mb, {
        lib     => catdir( $install_base, 'lib', 'perl5' ),
        arch    => catdir( $install_base, 'lib', 'perl5', $Config{archname} ),
        bin     => catdir( $install_base, 'bin' ),
        script  => catdir( $install_base, 'bin' ),
        bindoc  => catdir( $install_base, 'man', 'man1'),
        libdoc  => catdir( $install_base, 'man', 'man3' ),
        binhtml => catdir( $install_base, 'html' ),
        libhtml => catdir( $install_base, 'html' ),
    });
}


sub test_prefix {
    my ($prefix, $test_config) = @_;

    local $Test::Builder::Level = $Test::Builder::Level + 1;

    foreach my $type (qw(lib arch bin script bindoc libdoc binhtml libhtml)) {
        my $dest = $mb->install_destination( $type );
	ok $mb->dir_contains($prefix, $dest), "$type prefixed";

        SKIP: {
	    skip( "'$type' not configured", 1 )
	      unless $test_config && $test_config->{$type};

	    have_same_ending( $dest, $test_config->{$type},
			      "  suffix correctish " .
			      "($test_config->{$type} + $prefix = $dest)" );
        }
    }
}

sub have_same_ending {
  my ($dir1, $dir2, $message) = @_;

  $dir1 =~ s{/$}{} if $^O eq 'cygwin'; # remove any trailing slash
  my @dir1 = splitdir $dir1;

  $dir2 =~ s{/$}{} if $^O eq 'cygwin'; # remove any trailing slash
  my @dir2 = splitdir $dir2;

  is $dir1[-1], $dir2[-1], $message;
}

sub test_install_destinations {
    my($build, $expect) = @_;

    local $Test::Builder::Level = $Test::Builder::Level + 1;

    while( my($type, $expect) = each %$expect ) {
        is( $build->install_destination($type), $expect, "$type destination" );
    }
}


chdir( $cwd ) or die "Can''t chdir to '$cwd': $!";
$dist->remove;

use File::Path;
rmtree( $tmp );


use strict;

use File::Spec;
BEGIN {
  my $common_pl = File::Spec->catfile('t', 'common.pl');
  require $common_pl;
}

use Test::More;

BEGIN {
  plan tests => 27;

  chdir( 't' ) if -d 't';

  push( @INC, 'lib' );
  require DistGen;
}

use Module::Build::ModuleInfo;
ok(1);


# class method C<find_module_by_name>
my $module = Module::Build::ModuleInfo->find_module_by_name(
               'Module::Build::ModuleInfo' );
ok( -e $module );


# fail on invalid module name
my $pm_info = Module::Build::ModuleInfo->new_from_module( 'Foo::Bar' );
ok( !defined( $pm_info ) );


# fail on invalid filename
my $file = File::Spec->catfile( 'Foo', 'Bar.pm' );
$pm_info = Module::Build::ModuleInfo->new_from_file( $file );
ok( !defined( $pm_info ) );


my $dist = DistGen->new();
$dist->regen();

# construct from module filename
$file = File::Spec->catfile( $dist->dirname, 'lib', 'Simple.pm' );
$pm_info =
    Module::Build::ModuleInfo->new_from_file( $file );
ok( defined( $pm_info ) );

# construct from module name, using custom include path
my $inc = File::Spec->catdir( qw( Simple lib ) );
$pm_info = Module::Build::ModuleInfo->new_from_module(
	     'Simple', inc => [ $inc, @INC ] );
ok( defined( $pm_info ) );


# parse various module $VERSION lines
my @modules = (
  <<'---', # declared & defined on same line with 'our'
package Simple;
our $VERSION = '1.23';
1;
---
  <<'---', # declared & defined on seperate lines with 'our'
package Simple;
our $VERSION;
$VERSION = '1.23';
1;
---
  <<'---', # use vars
package Simple;
use vars qw( $VERSION );
$VERSION = '1.23';
1;
---
  <<'---', # choose the right default package based on package/file name
package Simple::_private;
$VERSION = '0';
1;
package Simple;
$VERSION = '1.23'; # this should be chosen for version
1;
---
  <<'---', # just read the first $VERSION line
package Simple;
$VERSION = '1.23'; # we should see this line
$VERSION = eval $VERSION; # and ignore this one
1;
---
);

$dist = DistGen->new();
foreach my $module ( @modules ) {
 SKIP: {
    skip "No our() support until perl 5.6", 1 if $] < 5.006 && $module =~ /\bour\b/;

    $dist->change_file( 'lib/Simple.pm', $module );
    $dist->regen( clean => 1 );
    $file = File::Spec->catfile( $dist->dirname, 'lib', 'Simple.pm' );
    my $pm_info = Module::Build::ModuleInfo->new_from_file( $file );
    is( $pm_info->version, '1.23' );
  }
}
$dist->remove();


# parse $VERSION lines scripts for package main
my @scripts = (
  <<'---', # package main declared
#!perl -w
package main;
$VERSION = '0.01';
---
  <<'---', # on first non-comment line, non declared package main
#!perl -w
$VERSION = '0.01';
---
  <<'---', # after non-comment line
#!perl -w
use strict;
$VERSION = '0.01';
---
  <<'---', # 1st declared package
#!perl -w
package main;
$VERSION = '0.01';
package _private;
$VERSION = '999';
1;
---
  <<'---', # 2nd declared package
#!perl -w
package _private;
$VERSION = '999';
1;
package main;
$VERSION = '0.01';
---
  <<'---', # split package
#!perl -w
package main;
1;
package _private;
$VERSION = '999';
1;
package main;
$VERSION = '0.01';
1;
---
);

$dist = DistGen->new();
foreach my $script ( @scripts ) {
  $dist->change_file( 'bin/simple.plx', $script );
  $dist->regen();
  $pm_info =
    Module::Build::ModuleInfo->new_from_file( 'Simple/bin/simple.plx' );
  ok( defined( $pm_info ) && $pm_info->version eq '0.01' );
}


# examine properties of a module: name, pod, etc
$dist->change_file( 'lib/Simple.pm', <<'---' );
package Simple;
$VERSION = '0.01';
1;
package Simple::Ex;
$VERSION = '0.02';
1;
=head1 NAME

Simple - It's easy.

=head1 AUTHOR

Simple Simon

=cut
---
$dist->regen();

$pm_info = Module::Build::ModuleInfo->new_from_module(
             'Simple', inc => [ $inc, @INC ] );

is( $pm_info->name(), 'Simple' );

is( $pm_info->version(), '0.01' );

# got correct version for secondary package
is( $pm_info->version( 'Simple::Ex' ), '0.02' );

my $filename = $pm_info->filename();
ok( defined( $filename ) && length( $filename ) );

my @packages = $pm_info->packages_inside();
is( @packages, 2 );
is( $packages[0], 'Simple' );

# we can detect presence of pod regardless of whether we are collecting it
ok( $pm_info->contains_pod() );

my @pod = $pm_info->pod_inside();
is_deeply( \@pod, [qw(NAME AUTHOR)] );

# no pod is collected
my $name = $pm_info->pod('NAME');
ok( !defined( $name ) );


# collect_pod
$pm_info = Module::Build::ModuleInfo->new_from_module(
             'Simple', inc => [ $inc, @INC ], collect_pod => 1 );

$name = $pm_info->pod('NAME');
if ( $name ) {
  $name =~ s/^\s+//;
  $name =~ s/\s+$//;
}
is( $name, q|Simple - It's easy.| );



$dist->remove();

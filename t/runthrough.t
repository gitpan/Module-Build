######################### We start with some black magic to print on failure.

use Test;
BEGIN { plan tests => 10 }
use Module::Build;
use File::Spec;
use File::Path;
ok(1);

######################### End of black magic.

my $goto = File::Spec->catdir( Module::Build->cwd, 't', 'Sample' );
chdir $goto or die "can't chdir to $goto: $!";


my $build = new Module::Build
  (
   module_name => 'Sample',
  );
ok $build;

eval {$build->create_build_script};
ok !$@;

eval {$build->dispatch('test')};
ok !$@;

eval {$build->dispatch('disttest')};
ok !$@;

ok -e File::Spec->catdir('Sample-0.01', 'blib');

eval {$build->dispatch('distdir')};
ok !$@;

ok -e File::Spec->catdir('Sample-0.01', 'lib');

# The freshly run 'distdir' should never contain a blib/ directory, or
# else it could get into the tarball
ok not -e File::Spec->catdir('Sample-0.01', 'blib');

eval {$build->dispatch('realclean')};
ok !$@;

File::Path::rmtree( 'Sample-0.01', 0, 0 );

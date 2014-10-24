package Module::Build;

# $Id $

# This module doesn't do much of anything itself, it inherits from the
# modules that do the real work.  The only real thing it has to do is
# figure out which OS-specific module to pull in.  Many of the
# OS-specific modules don't do anything either - most of the work is
# done in Module::Build::Base.

use strict;
use File::Spec ();
use File::Path ();
use File::Basename ();

use vars qw($VERSION @ISA);
$VERSION = '0.05_01';

# Okay, this is the brute-force method of finding out what kind of
# platform we're on.  I don't know of a systematic way.  These values
# came from the latest (bleadperl) perlport.pod.

my %OSTYPES = qw(
		 aix       Unix
		 bsdos     Unix
		 dgux      Unix
		 dynixptx  Unix
		 freebsd   Unix
		 linux     Unix
		 hpux      Unix
		 irix      Unix
		 darwin    Unix
		 machten   Unix
		 next      Unix
		 openbsd   Unix
		 dec_osf   Unix
		 svr4      Unix
		 sco_sv    Unix
		 svr4      Unix
		 unicos    Unix
		 unicosmk  Unix
		 solaris   Unix
		 sunos     Unix
		 
		 dos       Windows
		 MSWin32   Windows
		 cygwin    Windows

		 os390     EBCDIC
		 os400     EBCDIC
		 posix-bc  EBCDIC
		 vmesa     EBCDIC

		 MacOS     MacOS
		 VMS       VMS
		 VOS       VOS
		 riscos    RiscOS
		 amigaos   Amiga
		 mpeix     MPEiX
		);

# We only use this once - don't waste a symbol table entry on it.
# More importantly, don't make it an inheritable method.
my $load = sub {
  my $mod = shift;
  #warn "Using $mod";
  eval "use $mod";
  die $@ if $@;
  @ISA = ($mod);
};

if (grep {-e File::Spec->catfile($_, qw(Module Build Platform), $^O) . '.pm'} @INC) {
  $load->("Module::Build::Platform::$^O");

} elsif (exists $OSTYPES{$^O}) {
  $load->("Module::Build::Platform::$OSTYPES{$^O}");

} else {
  warn "Unknown OS type '$^O' - using default settings\n";
  $load->("Module::Build::Platform::Default");
}

sub os_type { $OSTYPES{$^O} }

1;
__END__


=head1 NAME

Module::Build - Build and install Perl modules

=head1 SYNOPSIS

 Standard process for building & installing modules:
 
   perl Build.PL
   ./Build
   ./Build test
   ./Build install

=head1 DESCRIPTION

This is a beta version of a new module set I've been working on,
C<Module::Build>.  It is meant to be a replacement for
C<ExtUtils::MakeMaker>.

To install C<Module::Build>, and any other module that uses
C<Module::Build> for its installation process, do the following:

   perl Build.PL
   ./Build             # this script is created by 'perl Build.PL'
   ./Build test
   ./Build install

Actions defined so far include:

  build                          help        
  clean                          install     
  dist                           manifest    
  distcheck                      realclean   
  distclean                      skipcheck   
  distdir                        test        
  disttest                       testdb      
  fakeinstall                                


It's like the C<MakeMaker> metaphor, except that C<Build> is a short
Perl script, not a long Makefile.  State is stored in a directory called
C<_build/>.

Any customization can be done simply by subclassing C<Module::Build> and
adding a method called (for example) C<ACTION_test>, overriding the
default action.  You could also add a method called C<ACTION_whatever>,
and then you could perform the action C<./Build whatever>.

More actions will certainly be added to the core - it should be easy
to do everything that the MakeMaker process can do.  It's going to
take some time, though.  In the meantime, I may implement some
pass-through functionality so that unknown actions are passed to
MakeMaker.

For information on providing backward compatibility with
C<ExtUtils::MakeMaker>, see L<Module::Build::Compat>.

=head1 METHODS

I list here some of the most important methods in the
C<Module::Build>.  As the interface is still very unstable, I must ask
that for now, you read the source to get more information on them.
Normally you won't need to deal with these methods unless you want to
subclass C<Module::Build>.  But since one of the reasons I created
this module in the first place was so that subclassing is possible
(and easy), I will certainly write more docs as the interface
stabilizes.

=head2 $m = Module::Build->new(...)

Creates a new Module::Build object.  Arguments to the new() method are
listed below.  The only required argument is the C<module_name> argument.

=over 4

=item * module_name

The C<module_name> argument is required, and should be a string like
C<'Your::Module'>.  We use it for several purposes, including finding
the version string for this distribution, and creating a
suitably-named distribution directory.

=item * module_version

The C<module_version> argument is optional - if not explicitly
provided, we'll look for the version string in the module specified by
C<module_name>, parsing it out according to the same rules as
C<ExtUtils::MakeMaker> and C<CPAN.pm>.

=item * module_version_from

Allows you to specify an alternate file for finding the module
version, instead of looking in the file specified by C<module_name>.

=item * prereq

An optional C<prereq> argument specifies any module prerequisites that
the current module depends on.  The prerequisites are given in a hash
reference, where the keys are the module names and the values are
version specifiers:

 prereq => {Foo::Module => '2.4',
            Bar::Module => 0,
            Ken::Module => '>= 1.2, != 1.5, < 2.0'},

These three version specifiers have different effects.  The value
C<'2.4'> means that B<at least> version 2.4 of C<Foo::Module> must be
installed.  The value C<0> means that B<any> version of C<Bar::Module>
is acceptable, even if C<Bar::Module> doesn't define a version.  The
more verbose value C<'E<gt>= 1.2, != 1.5, E<lt> 2.0'> means that
C<Ken::Module>'s version must be B<at least> 1.2, B<less than> 2.0,
and B<not equal to> 1.5.  The list of criteria is separated by commas,
and all criteria must be satisfied.

=item * c_source

An optional C<c_source> argument specifies a directory which contains
C source files that the rest of the build may depend on.  Any C<.c>
files in the directory will be compiled to object files.  The
directory will be added to the search path during the compilation and
linking phases of any C or XS files.

=item * autosplit

An optional C<autosplit> argument specifies a file which should be run
through the C<Autosplit::autosplit()> function.  In general I don't
consider this a great idea, and I may even go so far as to remove this
feature later.  Let me know if I shouldn't.

=back

=head2 $m->add_to_cleanup

A C<Module::Build> method may call C<< $self->add_to_cleanup(@files) >>
to tell C<Module::Build> that certain files should be removed when the
user performs the C<Build clean> action.  I decided to make this a
dynamic method, rather than a static list of files, because these
static lists can get difficult to manage.  I preferred to keep the
responsibility for registering temporary files close to the code that
creates them.

=head2 Module::Build->resume

You'll probably never call this method directly, it's only called from
the auto-generated C<Build> script.  The C<new()> method is only
called once, when the user runs C<perl Build.PL>.  Thereafter, when
the user runs C<Build test> or another action, the C<Module::Build>
object is created using the C<resume()> method.

=head2 $m->dispatch

This method is also called from the auto-generated C<Build> script.
It parses the command-line arguments into an action and an argument
list, then calls the appropriate routine to handle the action.
Currently (though this may change), an action C<foo> will invoke the
C<ACTION_foo> method.  All arguments (including everything mentioned
in L<ACTIONS> below) are contained in the C<< $self->{args} >> hash
reference.

=head2 $m->os_type

If you're subclassing Module::Build and some code needs to alter its
behavior based on the current platform, you may only need to know
whether you're running on Windows, Unix, MacOS, VMS, etc. and not the
fine-grained value of Perl's C<$^O> variable.  The C<os_type()> method
will return a string like C<Windows>, C<Unix>, C<MacOS>, C<VMS>, or
whatever is appropriate.  If you're running on an unknown platform, it
will return C<undef> - there shouldn't be many unknown platforms
though.

=head2 $m->check_installed_version($module, $version)

This method returns true or false, depending on whether (at least)
version C<$version> of module C<$module> is installed.  The C<$module>
argument is given as a string like C<"Data::Dumper">, and the
C<$version> argument can take any of the forms described in L<prereq>
above.  This allows very fine-grained version checking.

If the check fails, we return false and set C<$@> to an informative
error message.

If the check succeeds, the return value is the actual version of
C<$module> installed on the system.  This allows you to do the
following:

 my $installed = $m->check_installed_version('DBI', '1.15');
 if ($installed) {
   print "Congratulations, version $installed of DBI is installed.\n";
 } else {
   die "Sorry, you must install DBI.\n";
 }

If C<$version> is any nontrue value (notably zero) and any version of
C<$module> is installed, we return true.  In this case, if C<$module>
doesn't define a version, or if its version is zero, we return the
special value "0 but true", which is numerically zero, but logically
true.

=head1 ACTIONS

There are some general principles at work here.  First, each task when
building a module is called an "action".  These actions are listed
above; they correspond to the building, testing, installing,
packaging, etc. tasks.

Second, arguments are processed in a very systematic way.  Arguments
are always key=value pairs.  They may be specified at C<perl Build.PL>
time (i.e.  C<perl Build.PL sitelib=/my/secret/place>), in which case
their values last for the lifetime of the C<Build> script.  They may
also be specified when executing a particular action (i.e.
C<Build test verbose=1>), in which case their values last only for the
lifetime of that command.  Per-action command-line parameters take
precedence over parameters specified at C<perl Build.PL> time.

The build process also relies heavily on the C<Config.pm> module, and
all the key=value pairs in C<Config.pm> are available in 

C<< $self->{config} >>.  If the user wishes to override any of the
values in C<Config.pm>, she may specify them like so:

  perl Build.PL config='siteperl=/foo perlpath=/wacky/stuff'

Not the greatest interface, I'm looking for alternatives.  Speak now!
Maybe:

  perl Build.PL config-siteperl=/foo config-perlpath=/wacky/stuff

or something.

The following build actions are provided by default.

=over 4

=item * help

This action will simply print out a message that is meant to help you
use the build process.  It will show you a list of available build
actions too.

=item * build

This is analogous to the MakeMaker 'make' target with no arguments.
By default it just creates a C<blib/> directory and copies any C<.pm>
and C<.pod> files from your C<lib/> directory into the C<blib/>
directory.  It also compiles any C<.xs> files from C<lib/> and places
them in C<blib/>.  Of course, you need a working C compiler
(preferably the same one that built perl itself) for this to work
properly.

Note that in contrast to MakeMaker, this module only (currently)
handles C<.pm>, C<.pod>, and C<.xs> files.  They must all be in the
C<lib/> directory, in the directory structure that they should have
when installed.

If you run the C<Build> script without any arguments, it runs the
C<build> action.

In future releases of C<Module::Build> the C<build> action should be
able to process C<.PL> files.  The C<.xs> support is currently in
alpha.  Please let me know if it works for you.

=item * test

This will use C<Test::Harness> to run any regression tests and report
their results.  Tests can be defined in the standard places: a file
called C<test.pl> in the top-level directory, or several files ending
with C<.t> in a C<t/> directory.

If you want tests to be 'verbose', i.e. show details of test execution
rather than just summary information, pass the argument C<verbose=1>.

If you want to run tests under the perl debugger, pass the argument
C<debugger=1>.

In addition, if a file called C<visual.pl> exists in the top-level
directory, this file will be executed as a Perl script and its output
will be shown to the user.  This is a good place to put speed tests or
other tests that don't use the C<Test::Harness> format for output.

=item * testdb

This is a synonym for the 'test' action with the C<debugger=1>
argument.

=item * clean

This action will clean up any files that the build process may have
created, including the C<blib/> directory (but not including the
C<_build/> directory and the C<Build> script itself).

=item * realclean

This action is just like the C<clean> action, but also removes the
C<_build> directory and the C<Build> script.  If you run the
C<realclean> action, you are essentially starting over, so you will
have to re-create the C<Build> script again.

=item * install

This action will use C<ExtUtils::Install> to install the files from
C<blib/> into the correct system-wide module directory.  The directory
is determined from the C<sitelib> entry in the C<Config.pm> module.
To install into a different directory, pass a different value for the
C<sitelib> parameter, like so:

 Build install sitelib=/my/secret/place/

Alternatively, you could specify the C<sitelib> parameter when you run
the C<Build.PL> script:

 perl Build.PL sitelib=/my/secret/place/

Under normal circumstances, you'll need superuser privileges to
install into the default C<sitelib> directory.

=item * fakeinstall

This is just like the C<install> action, but it won't actually do
anything, it will just report what it I<would> have done if you had
actually run the C<install> action.

=item * manifest

This is an action intended for use by module authors, not people
installing modules.  It will bring the F<MANIFEST> up to date with the
files currently present in the distribution.  You may use a
F<MANIFEST.SKIP> file to exclude certain files or directories from
inclusion in the F<MANIFEST>.  F<MANIFEST.SKIP> should contain a bunch
of regular expressions, one per line.  If a file in the distribution
directory matches any of the regular expressions, it won't be included
in the F<MANIFEST>.

The following is a reasonable F<MANIFEST.SKIP> starting point, you can
add your own stuff to it:

   ^_build
   ^Build$
   ^blib
   ~$
   \.bak$
   ^MANIFEST\.SKIP$
   CVS

See the L<distcheck> and L<skipcheck> actions if you want to find out
what the C<manifest> action would do, without actually doing anything.

=item * dist

This action is helpful for module authors who want to package up their
module for distribution through a medium like CPAN.  It will create a
tarball of the files listed in F<MANIFEST> and compress the tarball using
GZIP compression.

=item * distcheck

Reports which files are in the build directory but not in the
F<MANIFEST> file, and vice versa. (See L<manifest> for details)

=item * skipcheck

Reports which files are skipped due to the entries in the
F<MANIFEST.SKIP> file (See L<manifest> for details)

=item * distclean

Performs the 'realclean' action and then the 'distcheck' action.

=item * distdir

Creates a directory called C<$(DISTNAME)-$(VERSION)> (if that
directory already exists, it will be removed first).  Then copies all
the files listed in the F<MANIFEST> file to that directory.  This
directory is what people will see when they download your distribution
and unpack it.

=item * disttest

Performs the 'distdir' action, then switches into that directory and
runs a C<perl Build.PL>, followed by the 'build' and 'test' actions in
that directory.

=back

=head1 AUTOMATION

One advantage of Module::Build is that since it's implemented as Perl
methods, you can invoke these methods directly if you want to install
a module non-interactively.  For instance, the following Perl script
will invoke the entire build/install procedure:

 my $m = new Module::Build (module_name => 'MyModule');
 $m->dispatch('build');
 $m->dispatch('test');
 $m->dispatch('install');

If any of these steps encounters an error, it will throw a fatal
exception.

You can also pass arguments as part of the build process:

 my $m = new Module::Build (module_name => 'MyModule');
 $m->dispatch('build');
 $m->dispatch('test', verbose => 1);
 $m->dispatch('install', sitelib => '/my/secret/place/');

Building and installing modules in this way skips creating the
C<Build> script.

=head1 STRUCTURE

Module::Build creates a class hierarchy conducive to customization.
Here is the parent-child class hierarchy in classy ASCII art:

   /--------------------\
   |   Your::Parent     |  (If you subclass Module::Build)
   \--------------------/
            |
            |
   /--------------------\  (Doesn't define any functionality
   |   Module::Build    |   of its own - just figures out what
   \--------------------/   other modules to load.)
            |
            |
   /-----------------------------------\  (Some values of $^O may
   |   Module::Build::Platform::$^O    |   define specialized functionality.
   \-----------------------------------/   Otherwise it's ...::Default, a
            |                              pass-through class.)
            |
   /--------------------------\
   |   Module::Build::Base    |  (Most of the functionality of 
   \--------------------------/   Module::Build is defined here.)

=head1 SUBCLASSING

Right now, there are two ways to subclass Module::Build.  The first
way is to create a regular module (in a C<.pm> file) that inherits
from Module::Build, and use that module's class instead of using
Module::Build directly:

  ------ in Build.PL: ----------
  #!/usr/bin/perl
  
  use lib qw(/nonstandard/library/path);
  use My::Builder;  # Or whatever you want to call it
  
  my $m = My::Builder->new(module_name => 'Next::Big::Thing');
  $m->create_build_script;

This is relatively straightforward, and is the best way to do things
if your My::Builder class contains lots of code.  The
C<create_build_script()> method will ensure that the current value of
C<@INC> (including the C</nonstandard/library/path>) is propogated to
the Build script, so that My::Builder can be found when running build
actions.

For very small additions, Module::Build provides a C<subclass()>
method that lets you subclass Module::Build more conveniently, without
creating a separate file for your module:

  ------ in Build.PL: ----------
  #!/usr/bin/perl
  
  my $class = Module::Build->subclass
    (
     class => 'My::Builder',
     code => q{
      sub ACTION_foo {
        print "I'm fooing to death!\n";
      }
     },
    );
  
  my $m = $class->new(module_name => 'Module::Build');
  $m->create_build_script;

Behind the scenes, this actually does create a C<.pm> file, since the
code you provide must persist after Build.PL is run if it is to be
very useful.


=head1 MOTIVATIONS

There are several reasons I wanted to start over, and not just fix
what I didn't like about MakeMaker:

=over 4

=item *

I don't like the core idea of MakeMaker, namely that C<make> should be
involved in the build process.  Here are my reasons:

=over 4

=item +

When a person is installing a Perl module, what can you assume about
their environment?  Can you assume they have C<make>?  No, but you can
assume they have some version of Perl.

=item +

When a person is writing a Perl module for intended distribution, can
you assume that they know how to build a Makefile, so they can
customize their build process?  No, but you can assume they know Perl,
and could customize that way.

=back

For years, these things have been a barrier to people getting the
build/install process to do what they want.

=item *

There are several architectural decisions in MakeMaker that make it
very difficult to customize its behavior.  For instance, when using
MakeMaker you do C<use MakeMaker>, but the object created in
C<WriteMakefile()> is actually blessed into a package name that's
created on the fly, so you can't simply subclass
C<ExtUtils::MakeMaker>.  There is a workaround C<MY> package that lets
you override certain MakeMaker methods, but only certain explicitly
predefined (by MakeMaker) methods can be overridden.  Also, the method
of customization is very crude: you have to modify a string containing
the Makefile text for the particular target.

=item *

It is risky to make major changes to MakeMaker, since it does so many
things, is so important, and generally works.  C<Module::Build> is an
entirely seperate package so that I can work on it all I want, without
worrying about backward compatibility.

=item *

Finally, Perl is said to be a language for system administration.
Could it really be the case that Perl isn't up to the task of building
and installing software?  Absolutely not - see the C<Cons> package for
one example, at L<"http://www.dsmit.com/cons/"> .

=back

Please contact me if you have any questions or ideas.

=head1 TO DO

The current method of relying on time stamps to determine whether a
derived file is out of date isn't likely to scale well, since it
requires tracing all dependencies backward, it runs into problems on
NFS, and it's just generally flimsy.  It would be better to use an MD5
signature or the like, if available.  See C<cons> for an example.

The current dependency-checking for .xs files is prone to errors.  You
can make 'widowed' files by doing C<Build>, C<perl Build.PL>, and then
C<Build realclean>.  Should be easy to fix, but it's got me wondering
whether the dynamic declaration of dependencies is a good idea.

- make man pages and install them.
- append to perllocal.pod
- write .packlist in appropriate location (needed for un-install)

=head1 AUTHOR

Ken Williams, ken@mathforum.org

=head1 SEE ALSO

perl(1), ExtUtils::MakeMaker(3)

http://www.dsmit.com/cons/

=cut

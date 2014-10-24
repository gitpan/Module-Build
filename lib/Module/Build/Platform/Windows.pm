package Module::Build::Platform::Windows;

use strict;

use File::Basename;
use File::Spec;

use Module::Build::Base;

use vars qw(@ISA);
@ISA = qw(Module::Build::Base);

sub new {
  my $class = shift;
  my $self = $class->SUPER::new(@_);

  $self->_find_pl2bat();
  return $self;
}


sub _find_pl2bat {
  my $self = shift;
  my $cf = $self->{config};

  # Find 'pl2bat.bat' utility used for installing perl scripts.
  # This search is probably overkill, as I've never met a MSWin32 perl
  # where these locations differed from each other.

  my @potential_dirs;

  if ( $ENV{PERL_CORE} ) {

    require ExtUtils::CBuilder;
    @potential_dirs = File::Spec->catdir( ExtUtils::CBuilder->new()->perl_src(),
                                          qw/win32 bin/ );
  } else {
    @potential_dirs = map { File::Spec->canonpath($_) }
      @${cf}{qw(installscript installbin installsitebin installvendorbin)},
      File::Basename::dirname($self->{properties}{perl});
  }

  foreach my $dir (@potential_dirs) {
    my $potential_file = File::Spec->catfile($dir, 'pl2bat.bat');
    if ( -f $potential_file && !-d _ ) {
      $cf->{pl2bat} = $potential_file;
      last;
    }
  }
}

sub make_executable {
  my $self = shift;
  $self->SUPER::make_executable(@_);

  my $pl2bat = $self->{config}{pl2bat};

  if ( defined($pl2bat) && length($pl2bat) ) {
    foreach my $script (@_) {
      # Don't run 'pl2bat.bat' for the 'Build' script;
      # there is no easy way to get the resulting 'Build.bat'
      # to delete itself when doing a 'Build realclean'.
      next if ( $script eq $self->{properties}{build_script} );

      (my $script_bat = $script) =~ s/\.plx?//i;
      $script_bat .= '.bat' unless $script_bat =~ /\.bat$/i;

      my $status = $self->do_system("$self->{properties}{perl} $pl2bat < $script > $script_bat");
      if ( $status && -f $script_bat ) {
        $self->SUPER::make_executable($script_bat);
      } else {
        warn "Unable to convert '$script' to an executable.\n";
      }
    }
  } else {
    warn "Could not find 'pl2bat.bat' utility needed to make scripts executable.\n"
       . "Unable to convert scripts ( " . join(', ', @_) . " ) to executables.\n";
  }
}


sub manpage_separator {
    return '.';
}

sub split_like_shell {
  # As it turns out, Windows command-parsing is very different from
  # Unix command-parsing.  Double-quotes mean different things,
  # backslashes don't necessarily mean escapes, and so on.  So we
  # can't use Text::ParseWords::shellwords() to break a command string
  # into words.  The algorithm below was bashed out by Randy and Ken
  # (mostly Randy), and there are a lot of regression tests, so we
  # should feel free to adjust if desired.
  
  (my $self, local $_) = @_;
  
  return @$_ if defined() && UNIVERSAL::isa($_, 'ARRAY');
  
  my @argv;
  return @argv unless defined() && length();
  
  my $arg = '';
  my( $i, $quote_mode ) = ( 0, 0 );
  
  while ( $i < length() ) {
    
    my $ch      = substr( $_, $i  , 1 );
    my $next_ch = substr( $_, $i+1, 1 );
    
    if ( $ch eq '\\' && $next_ch eq '"' ) {
      $arg .= '"';
      $i++;
    } elsif ( $ch eq '\\' && $next_ch eq '\\' ) {
      $arg .= '\\';
      $i++;
    } elsif ( $ch eq '"' && $next_ch eq '"' && $quote_mode ) {
      $quote_mode = !$quote_mode;
      $arg .= '"';
      $i++;
    } elsif ( $ch eq '"' && $next_ch eq '"' && !$quote_mode &&
	      ( $i + 2 == length()  ||
		substr( $_, $i + 2, 1 ) eq ' ' )
	    ) { # for cases like: a"" => [ 'a' ]
      push( @argv, $arg );
      $arg = '';
      $i += 2;
    } elsif ( $ch eq '"' ) {
      $quote_mode = !$quote_mode;
    } elsif ( $ch eq ' ' && !$quote_mode ) {
      push( @argv, $arg ) if $arg;
      $arg = '';
      ++$i while substr( $_, $i + 1, 1 ) eq ' ';
    } else {
      $arg .= $ch;
    }
    
    $i++;
  }
  
  push( @argv, $arg ) if defined( $arg ) && length( $arg );
  return @argv;
}

1;

__END__

=head1 NAME

Module::Build::Platform::Windows - Builder class for Windows platforms

=head1 DESCRIPTION

The sole purpose of this module is to inherit from
C<Module::Build::Base> and override a few methods.  Please see
L<Module::Build> for the docs.

=head1 AUTHOR

Ken Williams <ken@cpan.org>, Randy W. Sims <RandyS@ThePierianSpring.org>

=head1 SEE ALSO

perl(1), Module::Build(3)

=cut

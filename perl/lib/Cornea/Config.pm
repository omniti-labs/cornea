package Cornea::Config;
use strict;

use strict;
use POSIX qw/uname/;

sub default_config_file { '/etc/cornea${host}.conf' }

{
  my %_g_Config = ();
  sub _g_Config {
    my $key = shift;
    $_g_Config{$key} = shift if @_;
    $_g_Config{$key};
  }
  sub _g_Config_unset { delete $_g_Config{shift}; }
  sub _g_Config_isset { exists $_g_Config{shift}; }
}

sub new {
    my $class = shift;
    $class->_init(@_) unless _g_Config_isset('config_file');
    return bless sub { die "Illegal access"; }, __PACKAGE__;
}

sub _init {
    my $class = shift;
    my $config_file = shift || $class->default_config_file;
    my @uname = POSIX::uname();
    my $i = 0;
    foreach (qw/sysname nodename release version machine/) {
      _g_Config("sysinfo::$_", $uname[$i++]);
    }

    eval {
        my $host = ".$uname[1]";
        my $file = eval "\"$config_file\"";
        $class->read_config($file);
    };
    return unless $@;

    # There was an error, use the default config
    my $host = '';
    my $file = eval "\"$config_file\"";
    $class->read_config($file);
    return;
}

sub read_config {
    my ($class, $file) = @_;
    open(CONF, "<$file") || die "Could not read config file: $file";
    while(<CONF>) {
        next if /^\s*[;#]/;
        if(/^\s*([^\s=]+)\s*=\s*(.*)$/) {
          my $key = lc($1);
          (my $val = $2) =~ s/\s+$//;
          _g_Config($key, $val);
        }
    }
    close(CONF);
    _g_Config('config_file', $file);
}

sub get { _g_Config(lc($_[1])); }
sub set { _g_Config(lc($_[1]), $_[2]); }
sub unset { _g_Config_unset(lc($_[1])); }
sub isset { _g_Config_isset(lc($_[1])); }

1;
1;

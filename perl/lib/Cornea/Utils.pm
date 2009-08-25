package Cornea::Utils;

use strict;
use Carp;
use Socket;
use Switch;
use POSIX qw/uname/;
require "sys/syscall.ph";

sub my_ip {
    my @uname = POSIX::uname();
    my @addr = gethostbyname($uname[1]);
    my $name = gethostbyaddr($addr[4], AF_INET);
    die unless ($name eq $uname[1]);
    return inet_ntoa($addr[4]);
}

sub shuffle {
    my $array = shift;
    my $i;
    for ($i = @$array; --$i; ) {
        my $j = int rand ($i+1);
        next if $i == $j;
        @$array[$i,$j] = @$array[$j,$i];
    }
}

my %__units;
BEGIN {
  %__units = (
    'k' => 1024,
    'm' => 1024*1024,
    'g' => 1024*1024*1024,
    't' => 1024*1024*1024*1024,
  );
}
sub units {
  my $u = lc(shift);
  confess "bad unit: $u" unless exists($__units{$u});
  return $__units{$u};
}

my $little;
BEGIN { $little = unpack "C", pack "S", 1; }

sub unpack64 {
  my $str = shift;
  my $full;
  if ( not eval { $full = unpack( "Q", $str ); 1; } ) {
    my ($l,$h) = unpack "LL", $str;
    ($h,$l) = ($l,$h) unless $little;
    $full = $l + $h * (1 + ~0);
    die "number too large for perl!" if ($full+1 == $full);
  }
  return $full;
}
sub fsinfo {
  my $path = shift;
  switch($^O) {
    case 'darwin' {
      my $buf = '\0' x 4096;
      syscall(&SYS_statfs64, $path, $buf) == 0 or die "$!";
      my ($bsize, $iosize) = unpack "Ll", $buf;
      my $blocks = unpack64(substr($buf, 8, 8));
      my $bfree = unpack64(substr($buf, 16, 8));
      my $bavail = unpack64(substr($buf, 24, 8));
      my $files = unpack64(substr($buf, 32, 8));
      my $ffree = unpack64(substr($buf, 40, 8));
      my $bfactor = $bsize / 1024;
      return int($blocks * $bfactor), int(($blocks - $bavail) * $bfactor);
    }
    case 'solaris' {
      my $buf = '\0' x 4096;
      syscall(&SYS_statvfs, $path, $buf) == 0 or die "$!";
      my $fbasetype = unpack "Z16", substr($buf, 72, 16);
      die "Unsupported fs '$fbasetype' on solaris\n"
        unless ($fbasetype eq 'zfs');
      my $bsize = unpack64(substr($buf, 0, 8));
      my $frsize = unpack64(substr($buf, 8, 8));
      my $blocks = unpack64(substr($buf, 16, 8));
      my $bfree = unpack64(substr($buf, 24, 8));
      my $bavail = unpack64(substr($buf, 32, 8));
      my $files = unpack64(substr($buf, 40, 8));
      my $ffree = unpack64(substr($buf, 48, 8));
      my $favail = unpack64(substr($buf, 56, 8));
      my $fsid = unpack64(substr($buf, 64, 8));
      my $bfactor = $frsize / 1024;
      return int($blocks * $bfactor), int(($blocks - $bavail) * $bfactor);
    }
    else { die "Unsupported platform '$^O'.  Add support." };
  }
}

1;

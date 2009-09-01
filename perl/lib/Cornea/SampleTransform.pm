package Cornea::SampleTransform;

use strict;

sub new { return bless {}, shift; }

sub validate {
  my $self = shift;
  my $service_id = shift;
  return 1;
}

sub transform {
  my $self = shift;
  my ($serviceId, $input, $repInId, $repOutId) = @_;
  return $input;
}

1;

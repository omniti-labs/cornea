package Cornea::RepresentationInfo;
use strict;

=pod

=item serviceId (serviceId)

=item repId (unique id, per serviceId)

=item name (name of representation)

=item transformClass (perl class)

=item replicationCount (number of replicas required)

=item distance (distance between replicas)

=item byproductOf (repId, can be NULL for an original)

=cut

sub new_from_row {
  my $class = shift;
  my $hash = shift;
  bless $hash, $class;
}

sub serviceId { return shift->{service_id}; }
sub repId { return shift->{representation_id}; }
sub name { return shift->{representation_name}; }
sub transformClass { return shift->{transform_class}; }
sub replicationCount { return shift->{replication_count}; }
sub distance { return shift->{distance}; }
sub parallel { return (shift->{parallel_transform} =~ /^f(?:alse)?$/) ? 0 : 1 }

sub dependents {
  my $self = shift;
  my $rt = Cornea::RecallTable->new();
  unless(exists($self->{_dependents})) {
    $self->{_dependents} =
      [$rt->repInfoDependents($self->serviceId,
                              $self->repId)];
  }
  return @{$self->{_dependents}}
}

sub transform {
  my $self = shift;
  my ($serviceId, $input, $repInId, $repOutId) = @_;
  my $cls = $self->transformClass;
  eval "use $cls;";
  die $@ if($@);
  my $t = eval "$cls->new();";
  return $t->transform($serviceId, $input, $repInId, $repOutId);
}

sub validate {
  my $self = shift;
  my ($serviceId, $input) = @_;
  my $cls = $self->transformClass;
  eval "use $cls;";
  die $@ if($@);
  my $t = eval "$cls->new();";
  return $t->validate($serviceId, $input);
}

1;

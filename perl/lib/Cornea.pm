package Cornea;

use strict;
use Cornea::Config;
use Cornea::RepresentationInfo;
use Cornea::RecallTable;
use Cornea::Queue;
use Cornea::StorageNode;
use Cornea::StorageNodeList;

sub new {
  my $class = shift;
  $class = ref($class) ? ref $class : $class;
  bless {}, $class;
}

sub submit {
  my $self = shift;
  my $input = shift;
  my ($serviceId,$assetId) = @_;

  my $rt = Cornea::RecallTable->new();
  my $repinfo = $rt->repInfo($serviceId, 0);
  die "No 'submission (0)' representation for service $serviceId\n" unless $repinfo;
  $repinfo->validate($serviceId, $input);
  return $self->store($input, $serviceId, $assetId, 0);
}

sub store {
  my $self = shift;
  my $input = shift;
  my ($serviceId,$assetId,$repId) = @_;

  my $rt = Cornea::RecallTable->new();
  my $gold = undef;

  my $repinfo = $rt->repInfo($serviceId, $repId);
  my $N = $rt->getNodes('open');

  my $S = Cornea::StorageNodeList->new();
  foreach my $n ($N->items) {
    print STDERR "Attempting PUT to " . $n->fqdn . "\n" if $main::DEBUG;
    my ($rv, $data) = $n->put($input, $serviceId, $assetId, $repId);
    if ($rv) {
      $S->add($n);
      $N->remove($n);
      $gold = $n;
      print STDERR "PUT succeeded (is gold)\n" if $main::DEBUG;
      last;
    }
    else {
      print STDERR "Failed put to " . $n->fqdn . "\n$data\n" if $main::DEBUG;
      $N->remove($n);
    }
  }

  die "No nodes available" if($S->count == 0);

  while($S->count < $repinfo->replicationCount) {
    my $T = $N->copy();
    $T->removeWithin($S, $repinfo->distance);
    last if($T->count == 0); # can't find adequate nodes
    foreach my $n ($T->items) {
      print STDERR "Attempting COPY to " . $n->fqdn . "\n" if $main::DEBUG;
      my ($rv, $data) = $n->put($gold, $serviceId, $assetId, $repId);
      if ($rv) {
        $S->add($n);
        $N->remove($n);
        print STDERR "COPY succeeded\n" if $main::DEBUG;
        last; # break out and recalc so that distance is right
      }
      else {
        print STDERR "Failed copy to " . $n->fqdn . "\n$data\n" if $main::DEBUG;
        $T->remove($n);
      }
    }
    last if($T->count == 0); # can't find adequate working nodes
  }

  if ($S->count < $repinfo->replicationCount) {
    print STDERR "Replica count not reached.\n" if ($main::DEBUG);
    my $config = Cornea::Config->new();
    if($config->get('Replication::Lazy')) {
      foreach my $n ($S->items) { $n->delete($serviceId, $assetId, $repId); }
      die "Failed to reach required replication count";
    }
    else {
      my $copies_needed = $repinfo->replicationCount - $S->count;
      my $nodelist = join(',', map { $_->id() } ($S->items()));
      print STDERR "Queueing replication request\n" if ($main::DEBUG);
      if (not Cornea::Queue::enqueue('REPLICATE',
                                     { 'serviceId' => $serviceId,
                                       'assetId' => $assetId,
                                       'repId' => $repId,
                                       'copyOn' => $nodelist,
                                       'copies' => $copies_needed })) {
        foreach my $n ($S->items) { $n->delete($serviceId, $assetId, $repId); }
        die "Failed to reach required replication count";
      }
    }
  }
  if (not $rt->insert($serviceId,$assetId,$repId,$S)) {
    foreach my $n ($S->items) { $n->delete($serviceId, $assetId, $repId); }
    die "Failed to record metadata";
  }

  if (scalar($repinfo->dependents) > 0) {
    my $nodelist = join(',', map { $_->id() } ($S->items()));
    if (not Cornea::Queue::enqueue('PROCESS',
                                   { 'serviceId' => $serviceId,
                                     'assetId' => $assetId,
                                     'repId' => $repId,
                                     'copyOn' => $nodelist })) {
      foreach my $n ($S->items) { $n->delete($serviceId, $assetId, $repId); }
      die "Failed to queue work against asset";
    }
  }

  return $S;
}

sub process {
  my $self = shift;
  my $detail = shift;
  my $serviceId = $detail->{serviceId};
  my $assetId = $detail->{assetId};
  my $repId = $detail->{repId};
  my @nodeIds = split /,/, $detail->{copyOn};
  my $rt = Cornea::RecallTable->new();
  my $repinfo = $rt->repInfo($serviceId, $repId);
  return if(scalar($repinfo->dependents) == 0);
  my $N = Cornea::StorageNodeList->new();
  my $input = undef;

  my $AvailableNodes = $rt->getNodes(['open','closed']);

  # Find where it is, based on the work order.
  my %node_map;
  foreach (@nodeIds) { $node_map{$_}++; }
  foreach ($AvailableNodes->items()) { $N->add($_) if ($node_map{$_->id()}); }

  # Find it if we don't know where it is.
  $N = $rt->find($serviceId, $assetId, $repId) if ($N->items() == 0);
  foreach my $n ($N->items) {
    $input = $n->fetch($serviceId, $assetId, $repId);
    last if($input);
  }
  if (not defined $input) {
    $self->log("FAILED($serviceId, $assetId, $repId) -> fetch\n");
    return;
  }

  foreach my $deprepinfo ($repinfo->dependents) {
    my $repOutId = $deprepinfo->repId;
    my $output = undef;
    eval {
      $output = $deprepinfo->transform($serviceId, $input,
                                       $repinfo->repId, $repOutId);
    };
    if ($@ or not defined $output) {
      $self->log("FAILED($serviceId, $assetId, $repId) -> transform($repOutId)\n");
    }
    else {
      eval {
        $self->store($output, $serviceId, $assetId, $repOutId);
      };
      if($@) {
        $self->log("FAILED($serviceId, $assetId, $repId) -> store($repOutId)\n");
      }
    }
  }
  return 1;
}
sub replicate {
  my $self = shift;
  my $detail = shift;
  my $serviceId = $detail->{serviceId};
  my $assetId = $detail->{assetId};
  my $repId = $detail->{repId};
  my $copies = $detail->{copies};
  my @nodeIds = split /,/, $detail->{copyOn};
  my $rt = Cornea::RecallTable->new();
  my $repinfo = $rt->repInfo($serviceId, $repId);

  my $AvailableNodes = $rt->getNodes(['open','closed']);

  my $S = Cornea::StorageNodeList->new();
  # Find where it is, based on the work order.
  my %node_map;
  foreach (@nodeIds) { $node_map{$_}++; }
  foreach ($AvailableNodes->items()) { $S->add($_) if ($node_map{$_->id()}); }

  my $N = $rt->getNodes('open');
  if($S->items() == 0) {
    # We got a blind: "I don't think I have enough replicas" message
    # we find the copies and then determine how many we need.
    $S = $rt->find($serviceId, $assetId, $repId) if ($S->items() == 0);
    $S->remove(sub { $_[0]->state() eq 'decommissioned' });
    $copies = $repinfo->replicationCount - scalar($S->items);
  }
  my $C = Cornea::StorageNodeList->new();
  foreach my $n ($S->items) {
    $N->remove($n);
  }
  print STDERR "($serviceId,$assetId,$repId) stored: ".scalar($S->items).
               ", others: ".scalar($N->items).
               ", copies needed: $copies\n" if $main::DEBUG;
  while ($S->items() && $copies > 0) {
    my $T = $N->copy();
    $T->removeWithin($S, $repinfo->distance);
    if($T->count == 0) { # can't find adequate nodes
      print STDERR "Cannot find enough nodes with ".$repinfo->distance."\n";
      last;
    }
    foreach my $n ($T->items) {
      print STDERR "Attempting COPY to " . $n->fqdn . "\n" if $main::DEBUG;
      my ($rv, $data) = $n->put($S, $serviceId, $assetId, $repId);
      if ($rv) {
        $S->add($n);
        $C->add($n);
        $N->remove($n);
        $copies--;
        print STDERR "COPY succeeded\n" if $main::DEBUG;
        last; # break out and recalc so that distance is right
      }
      else {
        $T->remove($n);
        print STDERR "COPY failed: $data\n" if $main::DEBUG;
      }
    }
    last if($T->count == 0); # can't find adequate working nodes
  }

  # If the following updates fail, we only undo the strage changeset $C
  if ($copies > 0) {
    my $nodelist = join(',', map { $_->id() } ($S->items()));
    if (not Cornea::Queue::enqueue('REPLICATE',
                                   { 'serviceId' => $serviceId,
                                     'assetId' => $assetId,
                                     'repId' => $repId,
                                     'copyOn' => $nodelist,
                                     'copies' => $copies })) {
      foreach my $n ($C->items) { $n->delete($serviceId, $assetId, $repId); }
      die "Failed to reach required replication count";
    }
  }

  # we only update the changeset if there is one
  if (scalar($C->items) and not $rt->insert($serviceId,$assetId,$repId,$S)) {
    foreach my $n ($C->items) { $n->delete($serviceId, $assetId, $repId); }
    die "Failed to record metadata";
  }
  return 1;
}


sub worker {
  my $self = shift;
  my $queue = Cornea::Queue->new(@_);

  $queue->worker(
    sub {
      my $op = shift;
      my $detail = shift;
      if    ($op eq 'PROCESS')    { return $self->process($detail); }
      elsif ($op eq 'REPLICATE')  { return $self->replicate($detail); }
      else                        { $self->log("UNKNOWNE Queue op($op)\n"); }
      return 0;
    }
  );
}

1;

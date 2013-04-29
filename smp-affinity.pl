#!/usr/bin/perl
#
# USAGE
#
#   smp-affinity.pl [--cpumap FILE | --file FILE]
#
# Holger Eitzenberger <holger.eitzenberger@sophos.com>, 2013.

use strict;
use Getopt::Long;
use Data::Dumper;

our $VERSION = '0.4';
our $cfg;

my $verbose;
my ($no_rps, $no_xps);
my ($cpumap_path, $cfg_path);
my ($do_reset);
my %options = (
	'c|cpumap=s' => \$cpumap_path,
	'f|file=s' => \$cfg_path,
	'h|help' => sub { usage(0) },
	'no-rps' => \$no_rps,
	'no-xps' => \$no_xps,
	'reset' => \$do_reset,
	'v|verbose+' => \$verbose,
	'version' => sub { print "smp-affinity.pl $VERSION\n";  exit 0 },
);

Getopt::Long::config('bundling');
Getopt::Long::GetOptions %options or die;

if ($cpumap_path) {
	cpumap_apply($cpumap_path);
} elsif ($cfg_path) {
	config_apply($cfg_path);
} elsif ($do_reset) {
	config_reset();
} else {
	usage(1, "no config or cpumap specified");
}

exit 0;

sub itf_queue_get_irq
{
	my ($itfname, $queuenum) = @_;
	my $queue_irq = 0;

	open my $fh, '<', '/proc/interrupts' or die "interrupts: $!";

	while (my $line = <$fh>) {
		chomp $line;

		my @tokens = split /\s+/, $line;
		shift @tokens;

		my $irq = shift @tokens;
		# not an IRQ line
		next unless $irq =~ /^(\d+):/;
		my $irqnum = $1;

		my $if_queue = splice @tokens, -1;

		# FIXME support other formats
		if ($if_queue =~ /^$itfname$/) {
			# often this is only the Link Management IRQ, therefore
			# may be overwritten by next entry.
			$queue_irq = $irqnum;
		} elsif ($if_queue =~ /^$itfname-TxRx-$queuenum$/) {
			$queue_irq = $irqnum;
			last
		}
	}

	return $queue_irq;
}

sub itf_init_itf
{
	my ($itfs, $itfname) = @_;

	$itfs->{$itfname} = { NAME => $itfname, QUEUES => [] };
}

sub itf_init_queue
{
	my ($itf, $queuenum) = @_;

	if (defined ${$itf->{QUEUES}}[$queuenum]) {
		die "configuration entry for '$itf->{NAME}:$queuenum' already exists";
	}
	${$itf->{QUEUES}}[$queuenum] = {
			NUM => $queuenum, IRQ => 0,
			IRQ_MASK => 0,
			STEERING_MASK => 0,
		};
}

# set both IRQ_MASK and STEERING_MASK to same value
sub itf_add_queue
{
	my ($itfs, $itfname, $queuenum, $cpunum) = @_;

	my $itf = $itfs->{$itfname};
	unless (defined ${$itf->{QUEUES}}[$queuenum]) {
		itf_init_queue($itf, $queuenum);
	}

	my $queue = ${$itf->{QUEUES}}[$queuenum];

	$queue->{IRQ} = itf_queue_get_irq($itfname, $queuenum) or do {
		# FIXME probably better to ignore this entry, because
		# interface may be just DOWN
		die "$itfname:$queuenum: no IRQ found for this queue\n";
	};
	$queue->{IRQ_MASK} |= 1 << $cpunum;
	$queue->{STEERING_MASK} |= 1 << $cpunum;
}

sub itf_queue_set_irq_affinity
{
	my ($itfs, $itfname, $queuenum, $cpunum) = @_;

	my $itf = $itfs->{$itfname};
	unless (defined ${$itf->{QUEUES}}[$queuenum]) {
		itf_init_queue($itf, $queuenum);
	}

	my $queue = ${$itf->{QUEUES}}[$queuenum];

	$queue->{IRQ} = itf_queue_get_irq($itfname, $queuenum) or do {
		# FIXME probably better to ignore this entry, because
		# interface may be just DOWN
		die "$itfname:$queuenum: no IRQ found for this queue\n";
	};
	$queue->{IRQ_MASK} |= 1 << $cpunum;
}

sub itf_queue_set_steering_cpus
{
	my ($itfs, $itfname, $queuenum, $cpunum) = @_;

	my $itf = $itfs->{$itfname};
	unless (defined ${$itf->{QUEUES}}[$queuenum]) {
		itf_init_queue($itf, $queuenum);
	}

	my $queue = ${$itf->{QUEUES}}[$queuenum];

	$queue->{STEERING_MASK} |= 1 << $cpunum;
}

sub itf_cmp
{
	$a =~ /^(\D+)(\d+)/;
	my ($aname, $anum) = ($1, $2);
	$b =~ /^(\D+)(\d+)/;
	my ($bname, $bnum) = ($1, $2);
	if ($verbose > 2) {
		print "itf_cmp: aname=$aname anum=$anum bname=$bname bnum=$bnum\n";
	}

	return $aname cmp $bname if $aname ne $bname;
	return $anum <=> $bnum
}

sub dump_itfs
{
	my ($itfs) = @_;

	foreach my $itfname (sort itf_cmp keys %$itfs) {
		my $itf = $itfs->{$itfname} or die;

		print Dumper($itf);
	}
}

sub irq_set_affinity
{
	my ($irq, $mask) = @_;

	# IRQ 0 is the timer IRQ, consider it invalid
	die "will not configure timer IRQ 0" if $irq == 0;
	open my $fh, '>', "/proc/irq/$irq/smp_affinity" or do {
			die "irq$irq: smp_affinity: $!"
		};

	printf $fh "%x", $mask or die;
	printf "irq$irq: SMP affinity '%x'\n", $mask if $verbose > 1;
}

sub set_rps_affinity
{
	my ($itfname, $queuenum, $mask) = @_;

	# Disable RPS.  Note that specifying a mask of 0xffffffff is
	# different, as it enables RPS for all CPUs.
	$mask = 0x0 if $no_rps;

	my $path = "/sys/class/net/$itfname/queues/rx-$queuenum/rps_cpus";
	open my $fh, '>', "$path" or die "$itfname:$queuenum: $!";

	printf $fh "%x", $mask or die;
	printf "$itfname:$queuenum: RPS mask '%x'\n", $mask if $verbose > 1;
}

sub set_xps_affinity
{
	my ($itfname, $queuenum, $mask) = @_;

	# Disable XPS.  Note that specifying a mask of 0xffffffff is
	# different, as it enables XPS for all CPUs.
	$mask = 0x0 if $no_xps;

	my $path = "/sys/class/net/$itfname/queues/tx-$queuenum/xps_cpus";
	open my $fh, '>', "$path" or die "$itfname:$queuenum: $!";

	printf $fh "%x", $mask or die;
	printf "$itfname:$queuenum: XPS mask '%x'\n", $mask if $verbose > 1;
}

sub configure_itfs
{
	my ($itfs) = @_;

	foreach my $itfname (sort itf_cmp keys %$itfs) {
		my $itf = $itfs->{$itfname} or die;

		foreach my $queue (@{$itf->{QUEUES}}) {
			irq_set_affinity($queue->{IRQ}, $queue->{IRQ_MASK});
			set_rps_affinity($itfname, $queue->{NUM},
				$queue->{STEERING_MASK});
			set_xps_affinity($itfname, $queue->{NUM},
				$queue->{STEERING_MASK});
			printf "$itf->{NAME}:$queue->{NUM}: affinity=%x rps=%x xps=%x\n",
				$queue->{IRQ_MASK}, $queue->{STEERING_MASK},
				$queue->{STEERING_MASK} if $verbose;
		}
	}
}

sub config_apply
{
	my ($path) = @_;
	my %itfs;

	do $path or die "$path: $!\n";

	foreach my $itfname (sort itf_cmp keys %{$cfg->{INTERFACES}}) {
		my $itf = $cfg->{INTERFACES}{$itfname} or die;

		itf_init_itf(\%itfs, $itfname) unless exists $itfs{$itfname};

		foreach my $queue (ref($itf) eq 'ARRAY' ? @$itf : $itf) {
			foreach my $queuenum (@{$queue->{QUEUES}}) {
				if (exists $queue->{IRQ_CPUS}) {
					foreach my $cpunum (@{$queue->{IRQ_CPUS}}) {
						itf_queue_set_irq_affinity(\%itfs, $itfname, $queuenum,
							$cpunum);
					}
				}

				foreach my $cpunum (@{$queue->{CPUS}}) {
					itf_queue_set_irq_affinity(\%itfs, $itfname, $queuenum,
						$cpunum) if not exists $queue->{IRQ_CPUS};
					itf_queue_set_steering_cpus(\%itfs, $itfname, $queuenum,
						$cpunum);
				}
			}
		}
	}

	#dump_itfs(\%itfs);

	configure_itfs(\%itfs);
}

sub cpumap_apply
{
	my ($path) = @_;
	my %itfs;

	open my $fh, '<', $path or die "$path: $!";

	my $lineno;
	while (my $line = <$fh>) {
		chomp $line;
		$lineno++;

		my @tokens = split /\s+/, $line;
		my $cpu = shift @tokens;

		# EXAMPLE
		#
		#   cpu0: eth0:0 eth8:6 eth9:6
		if ($cpu !~ /^cpu(\d+):/) {
			usage(1, "$path:$lineno: $cpu: not a valid CPU");
		}
		my $cpunum = $1;

		foreach my $if_queue (@tokens) {
			if ($if_queue =~ /^(\S+):(\d+)$/) {
				my ($itf, $queuenum) = ($1, $2);

				itf_init_itf(\%itfs, $itf) unless exists $itfs{$itf};
				itf_add_queue(\%itfs, $itf, $queuenum, $cpunum);
			}
		}
	}

	# TODO check if all queues of NIC are set

	#dump_itfs(\%itfs);

	configure_itfs(\%itfs);
}

# reset state for all UP interfaces
sub config_reset
{
	my %itfs;

	open my $fh, '<', '/proc/interrupts' or die "interrupts: $!";

	while (my $line = <$fh>) {
		chomp $line;

		my @tokens = split /\s+/, $line;
		shift @tokens;

		my $irq = shift @tokens;
		# not an IRQ line
		next unless $irq =~ /^(\d+):/;
		my $irqnum = $1;

		# FIXME does not work for shared IRQs
		my $if_queue = splice @tokens, -1;

		# FIXME support other NICs
		if ($if_queue =~ /^(.+)-TxRx-(\d+)$/) {
			my ($itfname, $queuenum) = ($1, $2);

			irq_set_affinity($irqnum, 0xffffffff);
			set_rps_affinity($itfname, $queuenum, 0x0);
			set_xps_affinity($itfname, $queuenum, 0x0);
			printf "$itfname:$queuenum: affinity=0xffffffff rps=0x0 "
				. "xps=0x0\n" if $verbose;
		}
	}
}

sub usage
{
	my ($ret, $msg) = @_;

	print "smp-affinity.pl $msg\n" if $msg;

	print <<_EOT_;
smp-affinity.pl [OPTIONS]

OPTIONS

 -h
 --help         Show this help.

 -v
 --version      Show version.

_EOT_

	exit $ret
}

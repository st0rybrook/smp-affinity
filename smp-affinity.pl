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

# There are several cases to consider:
#
# Single IRQ for RX, TX and Link Management:
#
#  45:          3          0   PCI-MSI-edge      eth0
#  -> { LMI => 45 }
#
# IRQ for RX/TX, with additional Link Management IRQ (e1000e):
#
#  72:          0          0    PCI-MSI-edge      eth3
#  73:        661          0    PCI-MSI-edge      eth3-rx-0
#  74:          2        659    PCI-MSI-edge      eth3-tx-1
#  -> { LMI => 72, RX => 73, TX => 74 }
#
# Split RX/TX with Link Management, RX:
#
#  72:          0          0    PCI-MSI-edge      eth3
#  73:        661          0    PCI-MSI-edge      eth3-rxtx-0
#  -> { LMI => 72, RX => 73, TX => 73 }
sub itf_queue_get_irqs
{
	my ($itfname, $queuenum) = @_;
	my %irqs = ( LMI => 0, RX => 0, TX => 0 );

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

		# FIXME support other formats
		if ($if_queue =~ /^$itfname$/) {
			$irqs{LMI} = $irqnum;
		} elsif ($if_queue =~ /^$itfname-TxRx-$queuenum$/) {
			$irqs{RX} = $irqs{TX} = $irqnum;
			last
		} elsif ($if_queue =~ /^$itfname-rx-$queuenum$/) {
			$irqs{RX} = $irqnum;
		} elsif ($if_queue =~ /^$itfname-tx-$queuenum$/) {
			$irqs{TX} = $irqnum;
		}
	}


	return \%irqs
}

sub itf_init_itf
{
	my ($itfname) = @_;

	return {
			NAME => $itfname,
			LM_IRQ => undef,			# Link Management IRQ
			QUEUES => [],
		}
}

# Read interface info from /proc/interrupts.  Will return for each
# interface something like:
#
#  {
#    NAME => 'eth0',
#    LM_IRQ => 41,
#    QUEUES => [
#        { NUM => 0, RX_IRQ => 42, TX_IRQ => 43 },
#      ]
#  }
#
# RX_IRQ and TX_IRQ may be equal to LM_IRQ, or RX_IRQ may be equal to
# TX_IRQ.
sub itf_get_info
{
	my ($itfname) = @_;
	my $ii = itf_init_itf($itfname);

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

		# FIXME support other formats
		my ($queuenum, $rx_irq, $tx_irq);
		if ($if_queue =~ /^$itfname$/) {
			$ii->{LM_IRQ} = $irqnum;
		} elsif ($if_queue =~ /^$itfname-TxRx-(\d+)$/) {
			$queuenum = $1;
			$rx_irq = $tx_irq = $irqnum;
		} elsif ($if_queue =~ /^$itfname-rx-(\d+)$/) {
			$queuenum = $1;
			$rx_irq = $irqnum;
		} elsif ($if_queue =~ /^$itfname-tx-(\d+)$/) {
			$queuenum = $1;
			$tx_irq = $irqnum;
		}

		if (defined $queuenum) {
			unless (defined ${$ii->{QUEUES}}[$queuenum]) {
				itf_init_queue($ii, $queuenum);
			}

			my $queue = ${$ii->{QUEUES}}[$queuenum];
			$queue->{RX_IRQ} = $rx_irq if $rx_irq;
			$queue->{TX_IRQ} = $tx_irq if $tx_irq;
		}
	}

	return $ii
}

sub itf_init_queue
{
	my ($itf, $queuenum) = @_;

	if (defined ${$itf->{QUEUES}}[$queuenum]) {
		die "configuration entry for '$itf->{NAME}:$queuenum' already exists";
	}

	# A queue may consist of up to three IRQs (Link Management, RX, TX)
	${$itf->{QUEUES}}[$queuenum] = {
			NUM => $queuenum,
			RX_IRQ => 0,
			RX_IRQ_MASK => 0,
			TX_IRQ => 0,
			TX_IRQ_MASK => 0,
			STEERING_MASK => 0,
		};
}

# set all values (RX_IRQ_MASK, TX_IRQ_MASK and STEERING_MASK to
# same value
sub itf_add_queue
{
	my ($itf, $queuenum, $cpu) = @_;

	unless (defined ${$itf->{QUEUES}}[$queuenum]) {
		itf_init_queue($itf, $queuenum);
	}
	my $qi = ${$itf->{QUEUES}}[$queuenum];

	# No IRQs are set for virtual NICs (lo, tun, etc.).  Don't set the
	# mask there as well.
	$qi->{RX_IRQ_MASK} |= 1 << $cpu if $qi->{RX_IRQ};
	$qi->{TX_IRQ_MASK} |= 1 << $cpu if $qi->{TX_IRQ};
	$qi->{STEERING_MASK} |= 1 << $cpu;
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

sub queue_set_irq_affinity
{
	my ($itf, $queue) = @_;

	die unless exists $itf->{LM_IRQ};
	die unless exists $queue->{RX_IRQ};
	die unless exists $queue->{RX_IRQ_MASK};
	die unless exists $queue->{TX_IRQ};
	die unless exists $queue->{TX_IRQ_MASK};

	if ($queue->{RX_IRQ}) {
		irq_set_affinity($queue->{RX_IRQ}, $queue->{RX_IRQ_MASK});
	}
	if ($queue->{TX_IRQ} && $queue->{TX_IRQ} != $queue->{RX_IRQ}) {
		irq_set_affinity($queue->{TX_IRQ}, $queue->{TX_IRQ_MASK});
	}

	# TODO set LM IRQ as well?
	#irq_set_affinity($itf->{LMI}, 0xffffffff);
}

sub set_rps_affinity
{
	my ($itf, $queue) = @_;
	my $itfname = $itf->{NAME};
	my $queuenum = $queue->{NUM};
	my $mask = $queue->{STEERING_MASK};

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
	my ($itf, $queue) = @_;
	my $itfname = $itf->{NAME};
	my $queuenum = $queue->{NUM};
	my $mask = $queue->{STEERING_MASK};

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
			queue_set_irq_affinity($itf, $queue);
		
			set_rps_affinity($itf, $queue);
			set_xps_affinity($itf, $queue);
			printf "$itf->{NAME}:$queue->{NUM}: affinity=%x rps=%x xps=%x\n",
				$queue->{IRQ_MASK}, $queue->{STEERING_MASK},
				$queue->{STEERING_MASK} if $verbose;
		}
	}
}

# Determine mask for each of the three queue entities, notably
# 'rx', 'tx' and 'steering'.  By specifying 'steering' the mask
# for both RPS and XPS is returned.
sub get_irq_mask
{
	my ($queue_cfg, $ii, $what) = @_;
	my %fields = (
			rx => ['RX_IRQ_CPUS', 'IRQ_CPUS', 'CPUS' ],
			tx => ['TX_IRQ_CPUS', 'IRQ_CPUS', 'CPUS' ],
			steering => ['STEERING_CPUS', 'CPUS' ],
		);

	return unless $queue_cfg || not exists $fields{$what};

	foreach my $fld (@{$fields{$what}}) {
		if (exists $queue_cfg->{$fld}) {
			if (exists $queue_cfg->{$fld}) {
				my $mask;

				foreach my $cpu (@{$queue_cfg->{$fld}}) {
					$mask |= 1 << $cpu;
				}

				return $mask
			}
		}
	}
}

sub config_apply
{
	my ($path) = @_;
	my %itfs;

	do $path or die "$path: $!\n";

	foreach my $itfname (sort itf_cmp keys %{$cfg->{INTERFACES}}) {
		my $itf_cfg = $cfg->{INTERFACES}{$itfname};

		unless (exists $itfs{$itfname}) {
			$itfs{$itfname} = itf_get_info($itfname);
		}

		my $ii = $itfs{$itfname};
		foreach my $queue_cfg (@$itf_cfg) {
			foreach my $queuenum (@{$queue_cfg->{QUEUES}}) {
				my $qi = ${$ii->{QUEUES}}[$queuenum];

				$qi->{RX_IRQ_MASK} = get_irq_mask($queue_cfg, $ii, 'rx');
				unless ($qi->{RX_IRQ_MASK}) {
					die "$itfname:$queuenum: empty RX mask, config missing\n";
				}
				$qi->{TX_IRQ_MASK} = get_irq_mask($queue_cfg, $ii, 'tx');
				unless ($qi->{TX_IRQ_MASK}) {
					die "$itfname:$queuenum: empty TX mask, config missing\n";
				}
				$qi->{STEERING_MASK} = get_irq_mask($queue_cfg, $ii,
						'steering');
				unless ($qi->{STEERING_MASK}) {
					die "$itfname:$queuenum: empty steering mask, "
						. "config missing\n";
				}
			}
		}
	}

	dump_itfs(\%itfs) if $verbose > 1;

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
		my $cpu = $1;

		foreach my $if_queue (@tokens) {
			if ($if_queue =~ /^(\S+):(\d+)$/) {
				my ($itfname, $queuenum) = ($1, $2);

				unless (exists $itfs{$itfname}) {
					$itfs{$itfname} = itf_get_info($itfname);
				}
				itf_add_queue($itfs{$itfname}, $queuenum, $cpu);
			}
		}
	}

	# TODO check if all queues of NIC are set

	dump_itfs(\%itfs) if $verbose > 1;

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
		# FIXME support split RX/TX IRQs
		if ($if_queue =~ /^(.+)-TxRx-(\d+)$/) {
			my ($itfname, $queuenum) = ($1, $2);

			irq_set_affinity_all($irqnum, 0xffffffff);
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

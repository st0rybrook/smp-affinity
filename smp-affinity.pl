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

our $VERSION = '0.2';
our $cfg;

my $verbose;
my ($no_rps, $no_xps);
my ($cpumap_path, $cfg_path);
my %options = (
	'c|cpumap=s' => \$cpumap_path,
	'f|file=s' => \$cfg_path,
	'h|help' => sub { usage(0) },
	'no-rps' => \$no_rps,
	'no-xps' => \$no_xps,
	'v|verbose+' => \$verbose,
	'version' => sub { print "smp-affinity.pl $VERSION\n";  exit 0 },
);

Getopt::Long::config('bundling');
Getopt::Long::GetOptions %options or die;

if ($cpumap_path) {
	cpumap_apply($cpumap_path);
} elsif ($cfg_path) {
	config_apply($cfg_path);
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

sub itf_add_queue
{
	my ($itfs, $itfname, $queuenum, $cpunum) = @_;

	unless (exists $itfs->{$itfname}) {
		$itfs->{$itfname} = {
				NAME => $itfname, QUEUES => [],
			};
	}

	my $itf = $itfs->{$itfname};
	unless (defined ${$itf->{QUEUES}}[$queuenum]) {
		$itf->{QUEUES}[$queuenum] = {
				NUM => $queuenum, MASK => 0, IRQ => 0
			};
	}

	my $queue = ${$itf->{QUEUES}}[$queuenum];

	$queue->{IRQ} = itf_queue_get_irq($itfname, $queuenum) or do {
		# FIXME probably better to ignore this entry, because
		# interface may be just DOWN
		die "$itfname:$queuenum: no IRQ found for this queue\n";
	};
	$queue->{MASK} |= 1 << $cpunum;
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
			irq_set_affinity($queue->{IRQ}, $queue->{MASK});
			set_rps_affinity($itfname, $queue->{NUM}, $queue->{MASK});
			set_xps_affinity($itfname, $queue->{NUM}, $queue->{MASK});
			printf "$itf->{NAME}:$queue->{NUM}: affinity=%x rps=%x xps=%x\n",
				$queue->{MASK}, $queue->{MASK}, $queue->{MASK} if $verbose;
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

		foreach my $queue (ref($itf) eq 'ARRAY' ? @$itf : $itf) {
			foreach my $queuenum (@{$queue->{QUEUES}}) {
				foreach my $cpunum (@{$queue->{CPUS}}) {
					itf_add_queue(\%itfs, $itfname, $queuenum, $cpunum);
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

				itf_add_queue(\%itfs, $itf, $queuenum, $cpunum);
			}
		}
	}

	# TODO check if all queues of NIC are set

	#dump_itfs(\%itfs);

	configure_itfs(\%itfs);
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

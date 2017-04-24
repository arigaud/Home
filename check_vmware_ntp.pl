#!/usr/bin/perl
#
# check_vmware_ntp.pl - based on vi-check-host-time.pl written by Andrew Sullivan
#
# Copyright (C) 2016 Alexandre Rigaud <arigaud.prosodie.cap@free.fr>
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA  02111-1307, USA.
#
# Report bugs to:  nagiosplug-help@lists.sourceforge.net
#
# Examples:
#   Check all hosts connected to a vCenter server
#   ./check_vmware_ntp.pl --server your.vi.server --warning 3 --critical 1
#
#   Check a specific host
#   ./check_vmware_ntp.pl --server some.esxi.host
#   CRITICAL: some.esxi.host. is -369 seconds off!, 5 Configured NTP servers, service ntpd running|drift=-369s peers=5;1;3;1;3
#

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../";
use VMware::VIRuntime;
use Time::Local;
use lib "/usr/local/nagios/libexec";
use utils qw ($TIMEOUT %ERRORS &print_revision &support);

my %STATES = (
        0       => "OK",
        1       => "WARNING",
        2       => "CRITICAL",
        3       => "UNKNOWN",
);

my %opts = (
        warning => {
                default         => 1,
                type            => "=i",
                variable        => "warning",
                help            => "number of seconds that is tolerable for drift is alarmed as warning (default:1).",
                required        => 0,
        },
        critical => {
                default         => 3,
                type            => "=i",
                variable        => "critical",
                help            => "number of seconds that is tolerable for drift is alarmed as critical (default:3).",
                required        => 0,
        },
        'H' => {
                type            => '=s',
                variable        => 'VI_SERVER',
                help            => 'VI server to connect to. Required if url is not present',
                required        => 0,
        },
        peer_warning => {
                default         => 3,
                type            => "=i",
                variable        => "peer_warning",
                help            => "Set the warning threshold for number of peers (default:3).",
                required        => 0,
        },
        peer_critical => {
                default         => 1,
                type            => "=i",
                variable        => "peer_critical",
                help            => "Set the warning threshold for number of peers (default:1).",
                required        => 0,
        },
);

my $list;
my $msg = "";
my $drift;
my $ret = 3;

Opts::add_options(%opts);
Opts::parse();
if( !Opts::option_is_set('server') )
{
        my $hostname = Opts::get_option('H');
        if( defined($hostname) && $hostname ne '' )
        {
                Opts::set_option('server', $hostname);
        }
}
Opts::validate();
Util::connect();

my $warn = Opts::get_option('warning');
my $crit = Opts::get_option('critical');
my $peer_warn = Opts::get_option('peer_warning');
my $peer_crit = Opts::get_option('peer_critical');

$TIMEOUT = 3;
# Just in case of problems, let's not hang Nagios
$SIG{'ALRM'} = sub {
        print "UNKNOWN - Plugin Timed out\n";
        exit $ERRORS{"UNKNOWN"};
};
alarm($TIMEOUT);


# get only hosts that are connected to vCenter, get only the name and dateTimeSystem MOR
my $hosts = Vim::find_entity_views(
view_type => 'HostSystem',
filter => {
        'summary.runtime.connectionState' => "connected"
}#,
#   properties => [ 'summary.config.name', 'configManager.dateTimeSystem' ]
);

foreach my $host (@$hosts)
{
        # get the date of the system and all the parts so we can convert to epoch time
        my $dts = Vim::get_view( mo_ref => $host->get_property('configManager.dateTimeSystem') );
        my $hosttime = $dts->QueryDateTime();
        my ($year, $month, $day, $hour, $minutes, $seconds) = $hosttime =~ /(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2}).*/;

        # do the convertion to epoch time
        my $hostepoch = timegm($seconds, $minutes, $hour, $day, $month - 1, $year - 1900);

        # get the epoch time for the local system
        my $localtime = time();

        # count ntp servers configured
        my $ntp_srv_count = list($dts);

        # check for drift, output something
        $drift = $hostepoch - $localtime;
        if ( abs($drift) > $crit) {
                $msg .= $host->get_property('summary.config.name') . " is " . ($drift) . " seconds off!";
                $ret = 2;
        } elsif ( abs($drift) > $warn) {
                $msg .= $host->get_property('summary.config.name') . " is " . ($drift) . " seconds off!";
                $ret = 1;
        } else {
                $msg .= $host->get_property('summary.config.name') . " is within allowable drift (" . ($drift) . "s)";
                $ret = 0;
        }

        if ( $ntp_srv_count > $peer_warn )
        {
                $msg .= ", $ntp_srv_count Configured NTP servers";
        } elsif ($ntp_srv_count <= $peer_crit) {
                $msg .= ", only $ntp_srv_count Configured NTP servers!";
                $ret = 2;
        } elsif($ntp_srv_count <= $peer_warn) {
                $msg .= ", only $ntp_srv_count Configured NTP servers!";
                $ret = 1 if ($ret < 2);
        } else {
                $msg .= ", No NTP servers configured!";
                $ret = 2;
        }

        # get ntpd status
        my $serviceSystem = Vim::get_view(mo_ref => $host->get_property('configManager.serviceSystem') );
        my $services = $serviceSystem->serviceInfo->service;
        foreach(@$services) {
                if($_->key eq 'ntpd')
                {
                        if($_->running)
                        {
                                $msg .= ", service ntpd running";
                                $ret = 0 if (!defined $ret);
                        } else
                        {
                                $msg .= ", service ntpd not running";
                                $ret = 2;
                        }
                }
        }

        $msg .= "|drift=" . $drift . "s peers=$ntp_srv_count;$warn;$crit;$peer_crit;$peer_warn\n";
        print "$STATES{$ret}: $msg";
}
Util::disconnect();

if(length $msg eq 0){
    print "UNKNOWN - Error querying ESX server '".Opts::get_option('server')."'\n";
}

exit $ret;

## subs

sub get_servers {
        my ($dts) = @_;
        my $ntp_config = $dts->{dateTimeInfo}->{ntpConfig};
        if (defined($ntp_config)) {
                return $ntp_config->{server};
        }
        return undef;
}

sub list {
        my ($dts) = @_;
        my $servers = get_servers($dts);
        my $ntp_srv_count=0;
        if (defined($servers) && scalar(@$servers)) {
                foreach my $server (@$servers) {
                        $ntp_srv_count++;
                }
        }
        return $ntp_srv_count;
}


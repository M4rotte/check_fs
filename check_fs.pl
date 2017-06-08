#!/usr/bin/env perl
use strict;
use utf8;
#
# check_fs.pl: Check used/free/available blocks/inodes for a given filesystem. To be used as Nagios-like supervision plugin.
#
# Author: Stéphane THOMAS
# Date: 2017-06-08

my $help_message = << "__HEREDOC__";

Check for used/free/available blocks/inodes for a given filesystem against provided threshold values.

Usage: $0 [-h/--help] [-f <path>] [-t <check type>] [-w <warning threshold>] [-c <critical threshold>]

To get the list of available check types do: $0 -t list

__HEREDOC__

sub help_exit { print($help_message); exit(3) }

# About the 'smart match' operator (~~) : https://stackoverflow.com/questions/2383505/perl-if-element-in-list (should be ok for Perl ≥ 5.10)
use experimental qw(smartmatch); # OK got it, don’t warn me.

use Filesys::Df; # http://search.cpan.org/~iguthrie/Filesys-Df-0.92/Df.pm (Filesys::DfPortable ????)
use Getopt::Long;
use Switch;

# **We assume the FS uses 1kB blocks**. **This script has to be modified to handle other block size**
# Thresholds must be specified in kB for size values
# Performance data are converted to bytes for convenience (no need to play with scaling to get a nicely labeled Y axis when graphing the RRD…)
# Computed values (percentage of blocks/inodes free and percentage of blocks/inodes available) aren’t included in the perfdata

# TODO:
# Customizable perfdata content (the script write them all, whatever the check type is…)

# Limitations:
# 1. While it stores all information related to the filesytem into perfdata, it can only raises an alert for one particular check at once.
# 2. Percentages have an integer granularity
# 3. Like the df command, if a regular file is provided as argument, it returns informations on the related filesystem.
#    The script doesn’t check if the provided path *really* is a mounted filesystem.

my $fs_name       = '/'; # Check ROOTFS if no FS is specified. **NB: FS must be referred by their mountpoint, NOT their device name.**

# Available check types:
my @checkTypes    = ('total',
                     'used',
                     'perfree',
                     'free',
                     'avail',
                     'peravail',
                     'per',
                     'itotal',
                     'iused',
                     'perifree',
                     'periavail',
                     'ifree',
                     'iavail',
                     'iper');
                     
my $checkType     = 'per'; # If no type specified, check for used space percentage
my $warnThreshold = '90';  # Default warning threshold, obviously applies to the default check type above… 
my $critThreshold = '98';  # Default critical threshold, idem.

# The script ran without any argument corresponds to the following command line : 'check_fs.pl -f / -t per -w 90 -c 98'

# Thresholds are maximum limits for all check types,
# *except* for "free", "perfree", "peravail", "avail", "ifree", "perifree", "periavail" and "iavail",
# where they’re minimum limits (which makes more sense).

# Get command line arguments, return UNKNOWN if something goes wrong.
GetOptions('help|h' => \&help_exit, 'f=s{1}' => \$fs_name, 't=s{1}' => \$checkType, 'w=s{1}' => \$warnThreshold, 'c=s{1}' => \$critThreshold) or do {
    print("Wrong command line.\n"); exit(3)
};

# Verify check type, return UNKNOWN if it doesn’t exist.
if (!($checkType ~~ @checkTypes)) {
    print("Unknown check type: \"${checkType}\".\nCheck types are: "); foreach (@checkTypes) { print("\"$_\" ") }; print("\n"); exit(3)
};
# (as 'list' is not a valid check type, entering 'check_fs.pl -t list' will show the available check types…)

# Get the data  **if the Filesys::Df module is not available it would need to be replaced by the parsing of the 'df -Pk' command.
my $fs = df($fs_name);

# If we get something:
if(defined($fs)) {
    
    # Use bytes instead of 1k-blocks in perfdata.
    my $byte_thresholds = ($warnThreshold*1024).";".($critThreshold*1024);

    ## TODO: find more meaningful labels…
    my $perfdata  = "|'percent'=$fs->{per}%;$warnThreshold;$critThreshold ";
    $perfdata    .= "'total'=".($fs->{blocks}*1024)."B;".$byte_thresholds." ";
    $perfdata    .= "'used'=".($fs->{used}*1024)."B;".$byte_thresholds.";0;$fs->{blocks} ";
    $perfdata    .= "'free'=".($fs->{bfree}*1024)."B;".$byte_thresholds.";0;$fs->{blocks} ";
    $perfdata    .= "'avail'=".($fs->{bavail}*1024)."B;".$byte_thresholds.";0;$fs->{blocks} ";

    ## Check for existence of inodes information (they may be unavailable on some FS, like NFS)
    if(exists($fs->{files})) {
    
    $perfdata    .= "'ipercent'=$fs->{fper}%;$warnThreshold;$critThreshold ";
    $perfdata    .= "'itotal'=$fs->{files};".($warnThreshold*1024).";".($critThreshold*1024)." ";
    $perfdata    .= "'iused'=$fs->{fused};$warnThreshold;$critThreshold;0;$fs->{files} ";
    $perfdata    .= "'ifree'=$fs->{ffree};$warnThreshold;$critThreshold;0;$fs->{files} ";
    $perfdata    .= "'iavail'=$fs->{favail};$warnThreshold;$critThreshold;0;$fs->{files} ";
    
    } else { print("No inode data!"); }
    
    ## What to check ?
    # We check greater/less **or equal** for all test
    # Ex: For a "used space" check the alert will raise if the value goes *over* the limit,
    # for a "free space" check the alert will raise if the value goes *under* the limit.
    # If you need an alert if the FS has only 5% freespace, your threshold has to be 6.
    switch ($checkType) {
        
        # Percentage of used blocks
        case 'per' {
            
            if ($fs->{per} ge $critThreshold) { print("${fs_name} CRITICAL $fs->{per}% used (≥${critThreshold}%)${perfdata}\n"); exit(2); }
            elsif ($fs->{per} ge $warnThreshold) { print("$fs_name WARNING $fs->{per}% used (≥${warnThreshold}%)${perfdata}\n"); exit(1); }
            else { print("OK $fs_name $fs->{per}% used${perfdata}\n"); exit(0) }
        }
        
        # Percentage of free blocks
        case 'perfree' {
            
            if ((100 - $fs->{per}) le $critThreshold) { print("${fs_name} CRITICAL ".(100 - $fs->{per})."% free (≤${critThreshold}%)${perfdata}\n"); exit(2); }
            elsif ((100 - $fs->{per}) le $warnThreshold) { print("$fs_name WARNING ".(100 - $fs->{per})." free (≤${warnThreshold}%)${perfdata}\n"); exit(1); }
            else { print("OK $fs_name ".(100 - $fs->{per})."% free${perfdata}\n"); exit(0) }
        }
        
        # Percentage of available blocks
        case 'peravail' {
            
            if ((100*$fs->{bavail}/$fs->{blocks}) le $critThreshold) { print("${fs_name} CRITICAL ".int(100*$fs->{bavail}/$fs->{blocks})."% available (≤${critThreshold}%)${perfdata}\n"); exit(2); }
            elsif ((100*$fs->{bavail}/$fs->{blocks}) le $warnThreshold) { print("$fs_name WARNING ".int(100*$fs->{bavail}/$fs->{blocks})."% available (≤${warnThreshold}%)${perfdata}\n"); exit(1); }
            else { print("OK $fs_name ".int(100*$fs->{bavail}/$fs->{blocks})."% available${perfdata}\n"); exit(0) }
        }
        
        # Total blocks
        case 'total' {
            
            if ($fs->{blocks} ge $critThreshold) { print("${fs_name} CRITICAL $fs->{blocks}kB total (≥${critThreshold}kB)${perfdata}\n"); exit(2); }
            elsif ($fs->{blocks} ge $warnThreshold) { print("$fs_name WARNING $fs->{blocks}% total (≥${warnThreshold}kB)${perfdata}\n"); exit(1); }
            else { print("OK $fs_name $fs->{blocks}kB total${perfdata}\n"); exit(0) }
        }
        
        # Used blocks
        case 'used' {
            
            if ($fs->{used} ge $critThreshold) { print("${fs_name} CRITICAL $fs->{used}kB used (≥${critThreshold}kB)${perfdata}\n"); exit(2); }
            elsif ($fs->{used} ge $warnThreshold) { print("$fs_name WARNING $fs->{used}kB used (≥${warnThreshold}kB)${perfdata}\n"); exit(1); }
            else { print("OK $fs_name $fs->{used}kB used${perfdata}\n"); exit(0) }
        }
        
        # Free blocks
        case 'free' {
            
            if ($fs->{bfree} le $critThreshold) { print("${fs_name} CRITICAL $fs->{bfree}kB free (≤${critThreshold}kB)${perfdata}\n"); exit(2); }
            elsif ($fs->{bfree} le $warnThreshold) { print("$fs_name WARNING $fs->{bfree}kB free (≤${warnThreshold}kB)${perfdata}\n"); exit(1); }
            else { print("OK $fs_name $fs->{bfree}kB free${perfdata}\n"); exit(0) }
        }
        
        # Available blocks
        case 'avail' {
            
            if ($fs->{bavail} le $critThreshold) { print("${fs_name} CRITICAL $fs->{bavail}kB available (≤${critThreshold}kB)${perfdata}\n"); exit(2); }
            elsif ($fs->{bavail} le $warnThreshold) { print("$fs_name WARNING $fs->{bavail}kB available (≤${warnThreshold}kB)${perfdata}\n"); exit(1); }
            else { print("OK $fs_name $fs->{bavail}kB available${perfdata}\n"); exit(0) }
        }
    }
    
    # Can we check inodes ?
    if(exists($fs->{files})) {
        
        switch ($checkType) {
            
            # Percentage of used inodes
            case 'iper' {
                
                if ($fs->{fper} ge $critThreshold) { print("${fs_name} CRITICAL $fs->{fper}% used inodes (≥${critThreshold}%)${perfdata}\n"); exit(2); }
                elsif ($fs->{fper} ge $warnThreshold) { print("$fs_name WARNING $fs->{fper}% used inodes (≥${warnThreshold}%)${perfdata}\n"); exit(1); }
                else { print("OK $fs_name $fs->{fper}% used inodes${perfdata}\n"); exit(0) }
            }
            
            # Percentage of free inodes
            case 'perifree' {
                
                if ((100 - $fs->{fper}) le $critThreshold) { print("${fs_name} CRITICAL ".(100 - $fs->{fper})."% free inodes (≤${critThreshold}%)${perfdata}\n"); exit(2); }
                elsif ((100 - $fs->{fper}) le $warnThreshold) { print("$fs_name WARNING ".(100 - $fs->{fper})." free inodes (≤${warnThreshold}%)${perfdata}\n"); exit(1); }
                else { print("OK $fs_name ".(100 - $fs->{fper})."% free inodes${perfdata}\n"); exit(0) }
            }
            
            # Percentage of available inodes
            case 'periavail' {
                
                if ((100*$fs->{favail}/$fs->{files}) le $critThreshold) { print("${fs_name} CRITICAL ".int(100*$fs->{favail}/$fs->{files})."% available inodes (≤${critThreshold}%)${perfdata}\n"); exit(2); }
                elsif ((100*$fs->{favail}/$fs->{files}) le $warnThreshold) { print("$fs_name WARNING ".int(100*$fs->{favail}/$fs->{files})."% available inodes (≤${warnThreshold}%)${perfdata}\n"); exit(1); }
                else { print("OK $fs_name ".int(100*$fs->{bavail}/$fs->{files})."% available inodes${perfdata}\n"); exit(0) }
            }
            
            # Total inodes
            case 'itotal' {
                
                if ($fs->{files} ge $critThreshold) { print("${fs_name} CRITICAL $fs->{files} total inodes (≥${critThreshold})${perfdata}\n"); exit(2); }
                elsif ($fs->{files} ge $warnThreshold) { print("$fs_name WARNING $fs->{files} total inodes (≥${warnThreshold})${perfdata}\n"); exit(1); }
                else { print("OK $fs_name $fs->{files} total inodes${perfdata}\n"); exit(0) }
            }
            
            # Used inodes
            case 'iused' {
                
                if ($fs->{fused} ge $critThreshold) { print("${fs_name} CRITICAL $fs->{fused} used inodes (≥${critThreshold})${perfdata}\n"); exit(2); }
                elsif ($fs->{fused} ge $warnThreshold) { print("$fs_name WARNING $fs->{fused} used inodes (≥${warnThreshold})${perfdata}\n"); exit(1); }
                else { print("OK $fs_name $fs->{fused} used inodes${perfdata}\n"); exit(0) }
            }
            
            # Free inodes
            case 'ifree' {
                
                if ($fs->{ffree} le $critThreshold) { print("${fs_name} CRITICAL $fs->{ffree} free inodes (≤${critThreshold})${perfdata}\n"); exit(2); }
                elsif ($fs->{bfree} le $warnThreshold) { print("$fs_name WARNING $fs->{ffree} free inodes (≤${warnThreshold})${perfdata}\n"); exit(1); }
                else { print("OK $fs_name $fs->{ffree} free inodes${perfdata}\n"); exit(0) }
            }
            
            # Available inodes
            case 'iavail' {
                
                if ($fs->{favail} le $critThreshold) { print("${fs_name} CRITICAL $fs->{favail} available inodes (≤${critThreshold})${perfdata}\n"); exit(2); }
                elsif ($fs->{favail} le $warnThreshold) { print("$fs_name WARNING $fs->{favail} available inodes (≤${warnThreshold})${perfdata}\n"); exit(1); }
                else { print("OK $fs_name $fs->{favail} available inodes${perfdata}\n"); exit(0) }
            }
        }
    }
    
} else {
    
    print("File \"$fs_name\" not found!\n"); exit(3);
}


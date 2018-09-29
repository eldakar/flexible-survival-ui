#!/usr/bin/env perl
#
# update_status.pl - Update the status data file for the UI
# Copyright (C) 2018  Inutt - https://gitlab.com/inutt/flexible-survival-ui
# 
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
# 
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# 
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.
#

# Note: This script is not intended to be called by the user - only automatically by tintin

binmode STDOUT, 'encoding(utf8)'; # required to correctly output unicode
use JSON;
use Path::Class;
use common::sense;
use Getopt::Long;

my $data_dir = dir($ENV{'data_dir'});
my $status_data_file = $data_dir->file("status.json"); # Where to look for misc status data

die("Couldn't read data_dir variable from environment") unless $data_dir;

sub read_json_file {
    my $filename = shift;
    my $contents = undef;
    if (-f $filename) {
        undef $/;
        open my $FILE, "<", $filename or die "Couldn't open file: $!";
        $contents = <$FILE>;
        close $FILE;
        $contents = decode_json($contents);
    };
    return $contents;
};


my $name = undef;
my $sex = undef;
my $sex_symbol = undef;
my $area = undef;
my $room = undef;
my $hazard = undef;
GetOptions(
    "name=s" => \$name,
    "sex=s" => \$sex,
    # No option for sex symbol, as it's automatically determined from $sex
    "area=s" => \$area,
    "room=s" => \$room,
    "hazard=s" => \$hazard,
);

my $status_data;
# Read in any currently stored data
if (-r $status_data_file) { $status_data = read_json_file($status_data_file); };

if ($sex) {
    # Only change the symbol if we're updating sex
    if    ($sex eq 'male')   { $sex_symbol = '♂' }
    elsif ($sex eq 'female') { $sex_symbol = '♀' }
    elsif ($sex eq 'herm')   { $sex_symbol = '⚥' }
    elsif ($sex eq 'neuter') { $sex_symbol = '⚲' }
    else                     { $sex_symbol = '💩' }; # Should be a noticible error condition...
};

# Add any new data supplied
$status_data->{'character'}->{'name'} = $name if $name;
$status_data->{'character'}->{'sex'} = $sex if $sex;
$status_data->{'character'}->{'sex_symbol'} = $sex_symbol if $sex_symbol;
$status_data->{'location'}->{'area'} = $area if $area;
$status_data->{'location'}->{'room'} = $room if $room;
$status_data->{'location'}->{'hazard'} = $hazard if $hazard;

open my $FILE, ">", $status_data_file or die "Couldn't open file to write new data: $!";
print $FILE encode_json($status_data);
close $FILE;

# Update the tmux environment variable for character sex so the status bar can be updated
system('${TMUX_CMD} set-environment -g fs_sex_symbol '.$status_data->{'character'}->{'sex_symbol'}.' && ${TMUX_RELOAD}');

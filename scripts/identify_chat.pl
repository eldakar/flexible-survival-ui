#!/usr/bin/env perl
#
# identify_chat.pl - Identify if a string is a chat message or not
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

use common::sense;
use JSON;
use Path::Class;
binmode STDOUT, 'encoding(utf8)'; # required to correctly output unicode

my $config_file = file($ENV{'config_file'});
my $config = read_json_file($config_file);
my @channels = split /\s+/, $config->{'fs'}->{'chat_channels'};

sub read_json_file {
    my $filename = shift;
    my $contents = undef;
    if (-f $filename) {
        undef $/;
        open my $FILE, "<", $filename or die "Couldn't open file: $!";
        $contents = <$FILE>;
        close $FILE;
		if ($contents) {
	        $contents = decode_json($contents);
		} else {
			return;
		};
    };
    return $contents;
};

my $input = join ' ', @ARGV;
my $colour_code = qr/(?:\e\[[\d;]+m)/;
$input =~ s/$colour_code//g;

my @vars = ($input =~ /^\[(.+?)\]/);
my $channel = $vars[0];
if ($channel && (grep /$channel/, @channels)) { say $channel } else { say "" };
say $input;
use Data::Dumper;print Dumper \@vars;

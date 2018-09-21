#!/usr/bin/env perl
#
# update_weather.pl - Refresh the weather data from OpenWeatherMap
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

binmode STDOUT, 'encoding(utf8)'; # required to correctly output unicode
use JSON;
use Path::Class;
use LWP::UserAgent;
use DateTime;
use common::sense;

my $API_KEY = "ba863b1f838394cdc9d6d23ba7c47b4b";
my $now = DateTime->now;
my $weather_data_file = file($ENV{'data_dir'}, "weather.json"); # Where to cache weather data
my $data_dir = dir($ENV{'data_dir'});
# OpenWeatherMap city ID for Eureka, California from http://bulk.openweathermap.org/sample/city.list.json.gz
# It's the closest OpenWeatherMap location to Fairhaven, and is the one used by the FS server. (See string parsing for '[weather id]')
my $FAIRHAVEN_CITY_ID = "5563397";
my $refresh_interval = 900; # API poll minimum interval (seconds)

die("Couldn't read data_dir variable from environment") unless $data_dir;

# Parse weather information and generate display
$now = DateTime->now;
my $weather;
my $rate_limited;
my $error_msg;
my $utime;


my $lwp = LWP::UserAgent->new('protocols_allowed' => ['https']);
my $last_update_time = (stat($weather_data_file))[9];
if ($last_update_time < 0) { $rate_limited = 1; };

# Read in the weather data (from API or file as appropriate)
if (($now->epoch() - $last_update_time > 1200) && !$rate_limited) {
    # Data is outdated (or missing) so refresh it
    my $response = $lwp->get("https://api.openweathermap.org/data/2.5/weather?"
                            ."id=".$FAIRHAVEN_CITY_ID
                            ."&appid=".$API_KEY
                            ."&units=metric"); # Always request data in metric, for easier comparisons

    if ($response->is_success) {
        $weather = $response->decoded_content();
    } elsif ($response->code == 429) {
        # OpenWeatherMap says we're asking too often, so back off as per their documentation
        # (Shouldn't happen normally, but handle it just in case)
        $rate_limited = 1;
        my $next_update_time = $now;
        if ($last_update_time > (3600 * 4)) {
            # Severe rate limiting in effect, wait 24 hours before checking again
            $next_update_time->add(hours=>24);
            $error_msg = "Severe rate limiting enabled";
        } else {
            # Rate limiting in effect, wait an hour before checking again
            $next_update_time->add(hours=>1);
            $error_msg = "Rate limiting enabled";
        };
        $utime = $next_update_time->epoch;
    } else {
        $error_msg = "Failed getting weather data: ".$response->code." ".$response->message;
    };
    
    $weather = decode_json($weather) if $weather;
    $weather->{'error_message'} = $error_msg if $error_msg;
    open my $file, ">", $weather_data_file or die("Couldn't open weather data file: $!");
    print $file encode_json($weather);
    close $file;
    utime $utime, $utime, $weather_data_file;
};

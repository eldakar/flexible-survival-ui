#!/usr/bin/env perl
#
# status.pl - Parse the weather and status data and produce a nice UI from it
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
use DateTime;
use DateTime::Event::Sunrise;
use Time::Duration;
use File::Pid;
use File::ChangeNotify;
use common::sense;
use Term::ANSIColor;
use sigtrap 'handler', \&tidy_up, 'normal-signals';

my $API_KEY = undef; # To be provided by user in config file
my $now = DateTime->now;
my $app_dir = dir($ENV{'app_dir'});
my $config_file = file($ENV{'config_file'});
my $data_dir = dir($ENV{'data_dir'});
my $weather_data_file = $data_dir->file("weather.json"); # Where to cache weather data
my $status_data_file = $data_dir->file("status.json"); # Where to look for misc status data
# OpenWeatherMap city ID for Eureka, California from http://bulk.openweathermap.org/sample/city.list.json.gz
# It's the closest OpenWeatherMap location to Fairhaven, and is the one used by the FS server. (See string parsing for '[weather id]')
my $FAIRHAVEN_CITY_ID = "5563397";

die("Couldn't read data_dir variable from environment") unless $data_dir;
die("Couldn't read config_file variable from environment") unless $config_file;

# Write our PID out to a file so we're easier to kill later if needed
my $pidfile = check_single_instance($data_dir->file("status_monitor.pid"));
END { tidy_up(); };
sub tidy_up { $pidfile->remove if $pidfile; exit }; # Remove pidfile on exit/kill

# --- Default Configuration ---
# Weather UI
my $UNITS = "metric"; # imperial|metric
my $PRECISE_WIND = 1; # 1 => Show wind speed and direction numerically, 0 => Only show textual description
my $TEMPERATURE_THRESHOLD_HOT = 24; # Maximum temperature for comfort (in user selected units)
my $TEMPERATURE_THRESHOLD_COLD = 8; # Minimum temperature for comfort (in user selected units)
# Status UI
my $status_ui_colour = 'ansi165';
my $status_ui_text_colour = 'ansi165';
# ----- End Configuration -----

# Parse config file
if (my $config = read_json_file($config_file)) {
    $API_KEY = $config->{'status'}->{'weather'}->{'api_key'};
    die("Must provide OpenWeatherMap API key in $config_file") unless $API_KEY;
    
    my $tmp_units = $config->{'status'}->{'weather'}->{'units'};
    if ($tmp_units) {
        if ($tmp_units eq 'metric' || $tmp_units eq 'imperial') {
            $UNITS = $tmp_units;
        } else {
            die "Units '".$tmp_units."' not valid";
        };
    };
    
    my $tmp_wind = $config->{'status'}->{'weather'}->{'precise_wind'};
    if ($tmp_wind) {
        if    ($tmp_wind eq 'true')  { $PRECISE_WIND = 1 }
        elsif ($tmp_wind eq 'false') { $PRECISE_WIND = 0 }
        else                         { die "precise_wind must be either 'true' or 'false'"}
    };
        
    my $tmp_threshold = $config->{'status'}->{'weather'}->{'temperature_threshold_hot'};
    if ($tmp_threshold) {
        if    ($tmp_threshold =~ /^-?\d+$/) { $TEMPERATURE_THRESHOLD_HOT = $tmp_threshold }
        else                                { die "temperature_threshold_hot must be either an integer"};
    };
    $tmp_threshold = $config->{'status'}->{'weather'}->{'temperature_threshold_cold'};
    if ($tmp_threshold) {
        if    ($tmp_threshold =~ /^-?\d+$/) { $TEMPERATURE_THRESHOLD_COLD = $tmp_threshold }
        else                                { die "temperature_threshold_cold must be either an integer"};
    };
};

# Appropriate unit symbols for the measurements returned by OpenWeatherMap
my %units = (
    imperial => {
        temperature => "\xb0F", # Fahrenheit
        speed => 'mph',
        convert_temperature_from_metric => sub { return (($_[0] * 1.8) + 32) }, # Celcius -> Farenheit
        convert_speed_from_metric => sub { return ($_[0] * 2.2369) }, # metres/second -> miles/hour
    },
    metric => {
        temperature => "\xb0C", # Celcius
        speed => 'm/s',
        convert_temperature_from_metric => sub { return $_[0] }, # no-op as already metric
        convert_speed_from_metric => sub { return $_[0] }, # no-op as already metric
    },
);

sub check_single_instance {
    my $pid_filename = shift;
    if (-e $pid_filename) {
        my $pidfile = File::Pid->new({ file => $pid_filename });
        if ($pidfile->running()) {
            # Script already running, so kill the old one
            kill 'KILL', $pidfile->pid();
        } else {
            # Stale PID file found, remove it so we can create a new one
            $pidfile->remove() or die "Failed to remove stale pid file from ".$pid_filename;
        }
    }
    my $pidfile = File::Pid->new({ file => $pid_filename });
    $pidfile->write();
    return $pidfile;
};

sub approx_duration {
    my $time = shift;
    if (ref $time eq "") { $time = DateTime->from_epoch(epoch=>$time) };
    return ago($now->epoch - $time->epoch, 1);
};

sub time_until_event {
    my $time = shift;
    if (ref $time eq "") { $time = DateTime->from_epoch(epoch=>$time) };
    return ago($now->epoch - $time->epoch, 1);
};

sub format_epoch {
    my $time = shift;
    if (ref $time eq "") { $time = DateTime->from_epoch(epoch=>$time) };
    return $time->strftime("%T %F %Z");
};

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



my $change_notifier = File::ChangeNotify->instantiate_watcher(
    directories => $data_dir->stringify,
    follow_symlinks => 1,
    filter => qr/^(weather\.json|status\.json)$/,
);
$| = 1; # Autoflush output so we don't need a blank line at the end of the output
system 'clear';
while (my @events = $change_notifier->wait_for_events()) {
    # Parse general status information and generate display
    my $status_data;
    
    foreach my $event (@events) {
        if ($event->type eq 'modify' || $event->type eq 'create') {
            # Read the data in from the file
            $status_data = read_json_file($status_data_file);
        } elsif ($event->type eq 'delete') {
            # Data was deleted, so use placeholders from below parsing
        } else {
            # Shouldn't happen
            print STDERR "Unknown event \"".$event->type."\" occurred with status file\n";
            next;
        };
    };
    
    # Fill in a placeholder if we couldn't determine the location
    $status_data->{'location'}->{'area'} = "ERROR: LOCATOR FAILURE" unless $status_data->{'location'}->{'area'};
    $status_data->{'location'}->{'room'} = "LOCATION UNKNOWN" unless $status_data->{'location'}->{'room'};
    
    my $hazard_text;
    my $hazard_colour;
    if    ($status_data->{'location'}->{'hazard'} eq "safe")      { $hazard_text = "=SECURED="; $hazard_colour = "ansi34" }
    elsif ($status_data->{'location'}->{'hazard'} eq "normal")    { $hazard_text = "HAZARDOUS"; $hazard_colour = "ansi172" }
    elsif ($status_data->{'location'}->{'hazard'} eq "dangerous") { $hazard_text = "DANGEROUS"; $hazard_colour = "ansi160" }
    else                                 { $hazard_text = "=UNKNOWN="; $hazard_colour = "ansi236" };
    
    my $location_padding = " " x ((32 - length($status_data->{'location'}->{'area'})) / 2);

    system 'clear';
    
    print "\n";
    printf "  %s ╭────                  ╭──── %s\n",
                    color($status_ui_colour),
                    color('reset');
    printf "  %s │ %s           %s          ╵%s Hazard monitoring system %s╷%s\n",
                    color($status_ui_colour),
                    color('black', 'on_'.$hazard_colour),
                    color('reset', $status_ui_colour),
                    color('bold', $status_ui_text_colour),
                    color($status_ui_colour),
                    color('reset');
    printf "     %s     ☣     %s     ╭────                       ────╯%s\n",
                    color('black', 'on_'.$hazard_colour),
                    color('reset', $status_ui_colour),
                    color('reset');
    printf "     %s           %s │   │ %s%s[%s]%s\n",
                    color('black', 'on_'.$hazard_colour),
                    color('reset', $status_ui_colour),
                    color('reset', $status_ui_text_colour),
                    $location_padding,
                    $status_data->{'location'}->{'area'},
                    color('reset');
    printf "     %s           %s │ %s      Current area rating: %s%s%s  %s │%s\n",
                    color('black', 'on_'.$hazard_colour),
                    color('reset', $status_ui_colour),
                    color('reset', $status_ui_text_colour),
                    color($hazard_colour),
                    $hazard_text, color('reset'),
                    color($status_ui_colour),
                    color('reset');
    printf "  %s           ────╯                                    ────╯%s\n",
                    color($status_ui_colour),
                    color('reset');


    print "\n";
    print color($status_ui_colour)."    ╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌\n".color('reset');
    print "\n";


    # Parse weather information and generate display
    $now = DateTime->now;
    my $weather;
    my $rate_limited;
    my $error_msg;
    
    # Read in the weather data (updated by the tintin timer script)
    my $weather = read_json_file($weather_data_file);

    # Read in the weather icon mapping
    my $weather_icons;
    {
        open my $file, "<", $app_dir->file("weather_icon_index.json") or die("Couldn't open icon index: $!");
        undef $/;
        $weather_icons = <$file>;
        close $file;
        $weather_icons = decode_json($weather_icons);
    };
    
    if ($weather) {
        my $temperature = $weather->{'main'}->{'temp'};
        my $humidity = $weather->{'main'}->{'humidity'};
        my $measurement_time = $weather->{'dt'};
        my $location = $weather->{'name'}.", ".$weather->{'sys'}->{'country'};
        my %coords = (
            longitude => $weather->{'coord'}->{'lon'},
            latitude  => $weather->{'coord'}->{'lat'},
        );
        my $owm_sunrise = $weather->{'sys'}->{'sunrise'};
        my $owm_sunset = $weather->{'sys'}->{'sunset'};
        my $wind_speed = $weather->{'wind'}->{'speed'};
        my $wind_angle = $weather->{'wind'}->{'deg'};
        my $wind_origin;
        if    ($wind_angle > 337.5 || $wind_angle < 22.5 ) { $wind_origin = "north";     }
        elsif ($wind_angle > 22.5  && $wind_angle < 67.5 ) { $wind_origin = "northeast"; }
        elsif ($wind_angle > 67.5  && $wind_angle < 112.5) { $wind_origin = "east";      }
        elsif ($wind_angle > 112.5 && $wind_angle < 157.5) { $wind_origin = "southeast"; }
        elsif ($wind_angle > 157.5 && $wind_angle < 202.5) { $wind_origin = "south";     }
        elsif ($wind_angle > 202.5 && $wind_angle < 247.5) { $wind_origin = "southwest"; }
        elsif ($wind_angle > 247.5 && $wind_angle < 292.5) { $wind_origin = "west";      }
        elsif ($wind_angle > 292.5 && $wind_angle < 337.5) { $wind_origin = "northwest"; }
        else                                               { $wind_origin = "sky (unknown direction)"; };
        my $cloud_cover = $weather->{'clouds'}->{'all'};
        my @weather_list = ();
        foreach my $condition (@{$weather->{'weather'}}) {
            push @weather_list, { group => lc($condition->{'main'}), detail => lc($condition->{'description'}) };
        };

        # Determine if we're in day or night
        my $daynight;
        my $sun_riseset;
        my $sun_time;
        my $weather_colour;
        
        # Calculate sunrise/set times rather than using the ones from OWM,
        # so we can also know tomorrow's sunrise if it's after sunset.
        my $s = DateTime::Event::Sunrise->new(%coords);
        my $daylight_hours = $s->sunrise_sunset_span($now);
        
        if ($daylight_hours->contains($now)) {
            $daynight = "day";
            $sun_riseset = "set";
            $sun_time = $daylight_hours->end;
            $weather_colour = 'ansi255';
        } else {
            $daynight = "night";
            $sun_riseset = "rise";
            $sun_time = $daylight_hours->start;
            if ($sun_time < $now) {
                $sun_time = $s->sunrise_datetime($now->clone->add(days=>1));
            };
            $weather_colour = 'ansi240';
        };

        # Primary weather type is listed first in the weather_list[] array
        my $primary_weather = $weather_list[0];
        my @secondary_weathers = @weather_list[2..-1];
        my $weather_icon = $weather_icons->{$primary_weather->{'group'}}->{$daynight} // $weather_icons->{$primary_weather->{'group'}}->{'default'} // $weather_icons->{'default'};
        my $wind_icon = $weather_icons->{'wind_direction'}->{$wind_origin};
        $weather_icon = chr(hex($weather_icon));
        $wind_icon = chr(hex($wind_icon));

        # Wind strengths from https://en.wikipedia.org/wiki/Beaufort_scale (all in m/s here)
        my $wind_strength;
        if    ($wind_speed <= 1.5)  {$wind_strength = ""                                       }
        elsif ($wind_speed <= 3.3)  {$wind_strength = color('ansi245')."A light breeze"        }
        elsif ($wind_speed <= 5.5)  {$wind_strength = color('ansi117')."A gentle breeze"       }
        elsif ($wind_speed <= 7.9)  {$wind_strength = color('ansi121')."A moderate breeze"     }
        elsif ($wind_speed <= 10.7) {$wind_strength = color('ansi084')."A fresh breeze"        }
        elsif ($wind_speed <= 13.8) {$wind_strength = color('ansi034')."A strong breeze"       }
        elsif ($wind_speed <= 17.7) {$wind_strength = color('ansi154')."A moderate gale"       }
        elsif ($wind_speed <= 20.7) {$wind_strength = color('ansi136')."A fresh gale"          }
        elsif ($wind_speed <= 24.4) {$wind_strength = color('ansi202')."A severe gale"         }
        elsif ($wind_speed <= 28.4) {$wind_strength = color('ansi126')."A storm wind"          }
        elsif ($wind_speed <= 32.6) {$wind_strength = color('ansi161')."A violent storm wind"  }
        else                        {$wind_strength = color('ansi196')."A hurricane force wind"};

        my $wind_string;
        if ($wind_strength) {
            # Construct a message for the wind component
            $wind_string = $wind_strength;
            if ($PRECISE_WIND) {
                $wind_string .= sprintf " (%.1f %s)", $units{$UNITS}{'convert_speed_from_metric'}->($wind_speed), $units{$UNITS}->{'speed'};
            };
            $wind_string .= " is blowing from the ".$wind_origin;
            if ($PRECISE_WIND) {
                $wind_string .= sprintf " (%.1f\xb0)", $wind_angle;
            };
        } else {
            # Special case for no wind (or very little wind)
            $wind_string = color('ansi242')."The air is calm, with little to no breeze";
        };
        $wind_string .= color('reset');
        
        my $temperature_colour = 'green';
        $temperature = $units{$UNITS}->{'convert_temperature_from_metric'}($temperature);
        $temperature_colour = 'blue' if $temperature < $TEMPERATURE_THRESHOLD_COLD;
        $temperature_colour = 'red' if $temperature > $TEMPERATURE_THRESHOLD_HOT;

        printf "             %s%d%s%s with %s%s\n", color($temperature_colour), $temperature, $units{$UNITS}->{'temperature'}, color($weather_colour), $primary_weather->{'detail'}, color('reset');
        printf "      %s%s%s      %s\n", color($weather_colour), $weather_icon, color('reset'), $wind_string;
        print "\n";
        printf "             %sSun%s is about %s%s\n", color($weather_colour), $sun_riseset, time_until_event($sun_time), color('reset');
        print "\n";
        unless ($error_msg) {
            printf "%s% 64s%s", color('ansi237'), "data was updated approximately ".approx_duration($measurement_time), color('reset');
        } else {
            printf "%s% 64s%s", color('ansi196'), $error_msg, color('reset');
        };
    } else {
        printf "      %sNo weather data available%s", color('ansi196'), color('reset');
    };
};

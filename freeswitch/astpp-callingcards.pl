#!/usr/bin/perl
#
# ASTPP - Open Source Voip Billing
#
# Copyright (C) 2004, Aleph Communications
#
# Darren Wiebe (darren@aleph-com.net)
#
# This program is Free Software and is distributed under the
# terms of the GNU General Public License version 2.
#############################################################################
use POSIX qw(ceil floor);
use POSIX qw(strftime);
use Time::HiRes qw( gettimeofday tv_interval );
use ASTPP;
use strict;
our $session;

use vars qw(@output $verbosity $config $astpp_db $cdr_db
  $ASTPP %stats %input $cc $pricelistinfo $brandinfo $sound @resellerlist $brand);
$stats{start_time} = [gettimeofday];
$cc                = 0;
$verbosity         = 1;
require "/usr/local/astpp/astpp-common.pl";

$ASTPP = ASTPP->new;
$ASTPP->set_verbosity($verbosity)
  ;    #Tell ASTPP debugging how verbose we want to be.

sub initialize() {
    $SIG{HUP} = 'ignore_hup'
      ;    # We ignore the HUP command that Asterisk sends on a call hangup.
    $config = &load_config();    # Load /var/lib/astpp/astpp-config.conf
    $astpp_db = &connect_db( $config, @output );
    $ASTPP->set_astpp_db($astpp_db);
    $config = &load_config_db( $astpp_db, $config );
    $brand = "brand";            #$AGI->get_variable("BRAND");
    if ( $brand && $brand ne "" ) {
        my $brandinfo = &get_cc_brand( $astpp_db, $brand );
        if ( $brandinfo->{reseller} ) {
            $config =
              &load_config_db_reseller( $astpp_db, $config,
                $brandinfo->{reseller} );
        }
        $config = &load_config_db_brand( $astpp_db, $config, $brand );
    }
    $cdr_db = &cdr_connect_db( $config, @output );
    $ASTPP->set_cdr_db($cdr_db);
    $sound = &define_sounds($astpp_db);
}

sub set_in_use()
{   # Set the "inuse" flag on the calling cards.  This prevents multiple people from
    # using the same card.
    my ( $cardinfo, $status ) = @_;
    my $sql;
    $sql =
        "UPDATE callingcards SET inuse = "
      . $astpp_db->quote($status)
      . " WHERE cardnumber = "
      . $astpp_db->quote( $cardinfo->{cardnumber} );
    $astpp_db->do($sql);
}

sub check_card() {    # Check a few things before saying the card is ok.
    my ($cardinfo) = @_;
    my $now = $astpp_db->selectall_arrayref("SELECT NOW() + 0")->[0][0];
    $ASTPP->debug(
        debug     => "Present Time: $now",
        verbosity => $verbosity
    );
    $ASTPP->debug(
        debug     => "Expiration Date: $cardinfo->{expiry}",
        verbosity => $verbosity
    );
    $ASTPP->debug(
        debug     => "Valid for Days: $cardinfo->{validfordays}",
        verbosity => $verbosity
    );
    $ASTPP->debug(
        debug     => "First Use: $cardinfo->{firstused}",
        verbosity => $verbosity
    );
    if ( $cardinfo->{inuse} != 0 )
    {    # If the card is in use then say so and leave.
        $session->streamFile( $sound->{card_inuse} );
        $session->streamFile( $sound->{goodbye} );
        &leave($cardinfo);
    }
    &set_in_use( $cardinfo, 1 )
      ;    # Now the card is in use and nobody else can use it.
    if (   $cardinfo->{firstused} eq "00000000000000"
        || $cardinfo->{firstused} eq "0000-00-00 00:00:00" )
    {      # If "firstused" has not been set, we will set it now.
            # At the same time we will update the "maint_day" field.
        my $sql =
          "UPDATE callingcards SET firstused = NOW() WHERE cardnumber = "
          . $astpp_db->quote( $cardinfo->{cardnumber} );
        $ASTPP->debug(
            debug     => $sql,
            verbosity => $verbosity
        );
        $astpp_db->do($sql);
        $sql =
            "UPDATE callingcards SET maint_day = DATE_ADD(NOW(), INTERVAL "
          . "$cardinfo->{maint_fee_days} day) WHERE cardnumber = "
          . $astpp_db->quote( $cardinfo->{cardnumber} );
        $ASTPP->debug(
            debug     => $sql,
            verbosity => $verbosity
        );
        if ( $cardinfo->{maint_fee_days} > 0 ) {
            $astpp_db->do($sql);
        }

        if ( $cardinfo->{validfordays} > 0 )
        { #Check if the card is set to expire and deal with that as appropriate.
            my $sql =
                "UPDATE callingcards SET expiry = DATE_ADD(NOW(), INTERVAL "
              . " $cardinfo->{validfordays} day) WHERE cardnumber = "
              . $astpp_db->quote( $cardinfo->{cardnumber} );
            $ASTPP->debug(
                debug     => $sql,
                verbosity => $verbosity
            );
            $astpp_db->do($sql);
            $cardinfo =
              &get_callingcard( $astpp_db, $cardinfo->{cardnumber}, $config );
        }
    }
    elsif ( $cardinfo->{validfordays} > 0 ) {
        my $now = $astpp_db->selectall_arrayref("SELECT NOW() + 0")->[0][0];
        $cardinfo->{expiry} = $astpp_db->selectall_arrayref(
            "SELECT DATE_FORMAT('$cardinfo->{expiry}' , '\%Y\%m\%d\%H\%i\%s')")
          ->[0][0];
        if ( $now >= $cardinfo->{expiry} ) {
            my $sql = "UPDATE callingcards SET status = 2 WHERE cardnumber = "
              . $astpp_db->quote( $cardinfo->{cardnumber} );
            $ASTPP->debug(
                debug     => $sql,
                verbosity => $verbosity
            );
            $astpp_db->do($sql);
            $sql = "DELETE FROM ani_map WHERE account = "
              . $astpp_db->quote( $cardinfo->{cardnumber} );
            $ASTPP->debug(
                debug     => $sql,
                verbosity => $verbosity
            );
            $astpp_db->do($sql);
            $session->streamFile( $sound->{card_has_expired} );
            $session->streamFile( $sound->{goodbye} );
            &leave($cardinfo);
        }
    }
    $ASTPP->debug(
        debug     => "Present Time: $now",
        verbosity => $verbosity
    );
    $ASTPP->debug(
        debug     => "Expiration Date: $cardinfo->{expiry}",
        verbosity => $verbosity
    );
    $ASTPP->debug(
        debug     => "Valid for Days: $cardinfo->{validfordays}",
        verbosity => $verbosity
    );
    $ASTPP->debug(
        debug     => "First Use: $cardinfo->{firstused}",
        verbosity => $verbosity
    );
}

sub tell_cost() {    #Say how much the call will cost.
    my ( $numberinfo, $pricelistinfo, $cardinfo ) = @_;
    if ( $pricelistinfo->{markup} ne "" && $pricelistinfo->{markup} != 0 ) {
        $ASTPP->debug(
            debug     => "Adding Markup of $pricelistinfo->{markup}",
            verbosity => $verbosity
        );
        $numberinfo->{connectcost} =
          $numberinfo->{connectcost} *
          ( ( $pricelistinfo->{markup} / 10000 ) + 1 );
        $numberinfo->{cost} =
          $numberinfo->{cost} * ( ( $pricelistinfo->{markup} / 10000 ) + 1 );
    }
    if ( $config->{calling_cards_rate_announce} == 1 ) {
        if ( $numberinfo->{cost} > 0 ) {
            my @call_cost = split( /\./, sprintf( "%.2f", $numberinfo->{cost} / 10000) );
            $session->streamFile( $sound->{call_will_cost} );
$ASTPP->debug( debug => "Call Cost Before Decimal: " . @call_cost[0]);
	    if (@call_cost[0] > 0) {
            	$session->execute(  "say", "en number pronounced " . @call_cost[0] );
	    	if (@call_cost[0] == 1) {
	            $session->streamFile( $sound->{main_currency} ) ;
	    	} else {
	            $session->streamFile( $sound->{main_currency_plural} ) ;
	    	}
	    }
$ASTPP->debug( debug => "Call Cost After Decimal: " . @call_cost[1]);
            if ( @call_cost[1] > 0 ) {
            	$session->execute(  "say", "en number pronounced "  . @call_cost[1] );
	    	if (@call_cost[1] == 1) {
	            $session->streamFile( $sound->{sub_currency} ) ;
	    	} else {
	            $session->streamFile( $sound->{sub_currency_plural} ) ;
	    	}
            }
            $session->streamFile( $sound->{per} );
            $session->streamFile( $sound->{minute} );
        }
        if ( $numberinfo->{connectcost} > 0 ) {
            $session->streamFile( $sound->{a_connect_charge} );
            my @connect_cost = split( /\./, sprintf( "%.2f", $numberinfo->{connectcost} / 10000) );
$ASTPP->debug( debug => "Connect Cost Before Decimal: " . @connect_cost[0]);
	    if (@connect_cost[0] > 0) {
            	$session->execute(  "say", "en number pronounced " . @connect_cost[0] );
	    	if (@connect_cost[0] == 1) {
	            $session->streamFile( $sound->{main_currency} ) ;
	    	} else {
	            $session->streamFile( $sound->{main_currency_plural} ) ;
	    	}
	    }
$ASTPP->debug( debug => "Connect Cost After Decimal: " . @connect_cost[1]);
            if ( @connect_cost[1] > 0 ) {
            	$session->execute(  "say", "en number pronounced "  . @connect_cost[1] );
	    	if (@connect_cost[1] == 1) {
	            $session->streamFile( $sound->{sub_currency} ) ;
	    	} else {
	            $session->streamFile( $sound->{sub_currency_plural} ) ;
	    	}
            }
            $session->streamFile( $sound->{will_apply} );
        }
    }
}

sub timelimit() {    #Calculate and say the time limit.
    my ( $numberinfo, $pricelistinfo, $cardinfo, $phoneno ) = @_;
    my ( $connectcost, $cost, $timelimit, $available, $maxtime, $balance );

    # Timelimit is in seconds
    if ( $cc == 0 ) {
        $available =
          ( $cardinfo->{value} - $cardinfo->{used} ) -
          $numberinfo->{connectcost};
        $ASTPP->debug(
            debug     => "FUNDS AVAILABLE: $available",
            verbosity => $verbosity
        );
    }
    elsif ( $cc == 1 ) {
        $balance = &accountbalance( $astpp_db, $cardinfo->{number} );
        $balance = ( $balance * -1 ) + ( $cardinfo->{credit_limit} );
        $available = ( $balance - $numberinfo->{connectcost} ) / 100;
    }
    if ( $available > 0 && $numberinfo->{cost} > 0 ) {
        $timelimit = ( ( $available / $numberinfo->{cost} ) * 60 );
    }
    elsif ( $available >= 0 && $numberinfo->{cost} <= 0 ) {
        $timelimit = $config->{callingcards_max_length};
    }
    if ( $timelimit > $config->{callingcards_max_length} ) {
        $timelimit = $config->{callingcards_max_length};
    }
    $ASTPP->debug(
        debug     => "TIMELIMIT: $timelimit",
        verbosity => $verbosity
    );
    if ( $brandinfo->{reseller} ne "" ) {
        $ASTPP->debug(
            debug     => "THIS BRAND BELONGS TO $brandinfo->{reseller}!",
            verbosity => $verbosity
        );
        my $carddata = &get_account( $astpp_db, $brandinfo->{reseller} );
#               ($callstatus, $maxlength) = &max_length($astpp_db, $config, $carddata, $phoneno);
#               my $routeinfo = &get_route( $astpp_db, $config, $phoneno, $carddata->{pricelist},$carddata );
        my $minimumcharge       = $numberinfo->{cost};
        my $belongs_to_reseller = 1;
        while ( $belongs_to_reseller == 1 ) {
            $ASTPP->debug(
                debug     => "FINDING LIMIT FOR: $carddata->{number}",
                verbosity => $verbosity
            );
            push @resellerlist, $carddata->{number};
            $ASTPP->debug(
                debug =>
                  "PUSHING $carddata->{number} ONTO THE LIST OF RESELLERS",
                verbosity => $verbosity
            );
            my ( $resellercallstatus, $resellermaxlength ) =
              &max_length( $astpp_db, $config, $carddata, $phoneno );
            my $routeinfo =
              &get_route( $astpp_db, $config, $phoneno, $carddata->{pricelist},
                $carddata, "CC" );
            if ( $resellercallstatus != 1 ) {
                $carddata->{reseller} = "";
                $timelimit = 0;
            }
            elsif ( $resellermaxlength < $timelimit / 60 ) {
                $timelimit = $resellermaxlength * 60;
            }
            if ( $resellermaxlength < 1 || $routeinfo->{cost} > $minimumcharge )
            {
                $carddata->{reseller} = "";
                $timelimit = 0;
            }
            $ASTPP->debug(
                debug     => "RESELLER Max Length: $resellermaxlength",
                verbosity => $verbosity
            );
            $ASTPP->debug(
                debug     => "RESELLER Call Status: $resellercallstatus",
                verbosity => $verbosity
            );
            if ( $carddata->{reseller} && $carddata->{reseller} ne "" ) {
                $carddata = &get_account( $astpp_db, $carddata->{reseller} );
            }
            else {
                $belongs_to_reseller = 0;
            }
        }
    }
    else {
        $ASTPP->debug(
            debug     => "THIS BRAND DOES NOT BELONG TO A RESELLER!",
            verbosity => $verbosity
        );
    }
    $ASTPP->debug( debug => "TIMELIMIT: $timelimit", verbosity => $verbosity );
    my $minutes = sprintf( "%.0f", $timelimit /60 );
    $ASTPP->debug( debug => "MINUTES: $minutes", verbosity => $verbosity );
    if ( $minutes > 0 && $config->{calling_cards_timelimit_announce} == 1 ) {
        $session->streamFile( $sound->{call_will_last} );
        if ( $minutes == 1 ) {
            $session->execute(  "say", "en number pronounced " . $minutes );
            $session->streamFile( $sound->{minute} );
        }
        elsif ( $minutes > 1 ) {
            $session->execute(  "say", "en number pronounced " . $minutes );
            $session->streamFile( $sound->{minutes} );
        }
    }
    elsif ( $minutes < 1 ) {
        $session->streamFile( $sound->{not_enough_credit} );
        $session->streamFile( $sound->{goodbye} );
        &leave($cardinfo);
    }
    $ASTPP->debug(
        debug     => "Available: $available",
        verbosity => $verbosity
    );
#    $ASTPP->debug( debug => "Balance: $balance",  verbosity => $verbosity );
#    $ASTPP->debug( debug => "Max Time: $maxtime", verbosity => $verbosity );
    return $timelimit;
}

sub say_balance() {    #Calculate and say the card balance.
    my ($cardinfo) = @_;
    my ( $connectcost, $cost, $included, $sub_balance, $balance, $main_balance );
    if ( $cc == 0 ) {
        $balance = $cardinfo->{value} - $cardinfo->{used};
    }
    elsif ( $cc == 1 ) {
        $balance = &accountbalance( $astpp_db, $cardinfo->{number} );
        $balance = ( $balance * -1 ) + ( $cardinfo->{credit_limit} );
    }
    if ( $balance > 0 ) {
        my @split_balance = split( /\./, ( sprintf( "%.2f", $balance / 10000) ) );
#        $balance      = $balance / 10000;
#        $balance      = sprintf( "%.2f", $balance );
#        $sub_balance  = substr( $balance, -2, 2 );
#        $main_balance = substr( $balance, 0, -2 );
	if ($config->{debug} == 1) {
		print STDERR "BALANCE: $balance \n";
		print STDERR "BALANCE: " . sprintf( "%.0f", $balance / 10000) . "\n";
		print STDERR "SPLIT_BALANCE 0:  @split_balance[0] \n";
		print STDERR "SPLIT_BALANCE 1:  @split_balance[1] \n";
	}
        $session->streamFile( $sound->{card_has_balance_of} );
        if ( @split_balance[0] == 1 ) {
            $session->execute( "say", "en number pronounced " .  @split_balance[0] );
            $session->streamFile( $sound->{main_currency} );
        }
        elsif (  @split_balance[0] > 1 ) {
            $session->execute(  "say", "en number pronounced " .  @split_balance[0] );
            $session->streamFile( $sound->{main_currency_plural} );
        }
        if (  @split_balance[1] == 1 ) {
            $session->execute(  "say", "en number pronounced " . @split_balance[1] );
            $session->streamFile( $sound->{sub_currency} );
        }
        elsif (  @split_balance[1] > 1 ) {
            $session->execute(  "say", "en number pronounced " . @split_balance[1] );
            $session->streamFile( $sound->{sub_currency_plural} );
        }
    }
    else {
        $session->streamFile( $sound->{card_is_empty} );
        $session->streamFile( $sound->{goodbye} );
        &leave($cardinfo);
    }
    return $balance;
}

sub update_balance() {    #Update the available credit on the calling card.
    my ( $cardinfo, $charge ) = @_;
    my $sql =
        "UPDATE callingcards SET used = "
      . $astpp_db->quote( ($charge) + $cardinfo->{used} )
      . " WHERE cardnumber = "
      . $astpp_db->quote( $cardinfo->{cardnumber} );
    $astpp_db->do($sql);
}

sub dialout() {           # Rig up the LCR stuff and do the outbound dialing.
        # If a call does not go through we give the user the option
        # of trying again.
    my (
        $destination,   $timelimit, $numberinfo,
        $pricelistinfo, $cardinfo,  $brandinfo
    ) = @_;
    my ( $status, $count, $increment );
    $ASTPP->debug(
        debug     => "Looking for outbound Route",
        verbosity => $verbosity
    );
    my @outboundroutes =
      &get_outbound_routes( $astpp_db, $destination, $cardinfo, $numberinfo,
        @resellerlist );
    $count = @outboundroutes;
    if ( $count == 0 ) {
        $ASTPP->debug(
            debug     => "NO OUTBOUND ROUTES FOUND!",
            verbosity => $verbosity
        );
        my $order =
          $session->playAndGetDigits( 1, 1, 1,
            $config->{calling_cards_general_input_timeout},
            "#*", "$sound->{noanswer}", "", '^[0-9]+$' );
        if ( $order != 1 ) {
            &leave($cardinfo);
        }
    }
    $count = 0;
    foreach my $route (@outboundroutes) {
        my $callstart = localtime();
        $callstart = &prettytimestamp if $cc == 1;
        $session->execute( "set", "execute_on_answer=sched_hangup +" . $timelimit );
#        $session->execute( "export", "execute_on_answer=sched_hangup +" . $timelimit );
#	$session->execute( "set", "execute_on_answer=sched_broadcast", "+" . $timelimit - 60 . " one_minute_left.wav both");

        my ( $xml_string, $data_string ) = $ASTPP->fs_dialplan_xml_bridge(
            destination_number => $destination,
            route_prepend      => $route->{prepend},
            trunk_name         => $route->{trunk}
        );
        my $sql = $astpp_db->prepare( "SELECT provider FROM trunks WHERE name = '" 
		. $route->{trunk} ."'" );
        $sql->execute;
        my $trunkdata = $sql->fetchrow_hashref;
	$sql->finish;

        my ( $dialedtime, $uniqueid, $answeredtime, $clid );
        $session->execute( "export", "outbound_route=$route->{id}" );
        $session->execute( "export", "provider=$trunkdata->{provider}" );
        $session->execute( "export", "trunk=$route->{trunk}" );
        $session->execute( "export", "callingcard_destination=$destination" );

        if ( $cc == 1 ) {
            $session->execute( "export", "accountcode=$cardinfo->{accountcode}" );
            $session->execute( "export", "callingcard=$cardinfo->{number}" );
        }
        else {
            $session->execute( "export", "accountcode=$cardinfo->{accountcode}" );
            $session->execute( "export", "callingcard=$cardinfo->{cardnumber}" );
        }
#        $session->execute( "bridge", "$data_string" );
	$session->execute( "bridge", "$xml_string" );
        return 1;
    }
}

sub leave() {    # Prepare everything and then leave the calling card app.
    my ($cardinfo) = @_;
    my ($whatnow);
    my $retries = 0;
    &set_in_use( $cardinfo, 0 ) if $cc == 0;
    while ( $retries < 3 ) {
        $whatnow = $session->playAndGetDigits(
            1,
            1,
            1,
            $config->{calling_cards_general_input_timeout},
            "#*",
            "$sound->{astpp_callingcard_menu}",
            "",
            '^[0-9]+$'
        );
        $ASTPP->debug(
            debug     => "WHAT NEXT = $whatnow ",
            verbosity => $verbosity
        );
        if ( $cc == 1 ) {
            $session->execute( "export", "cardnumber=$cardinfo->{number}" );
            $session->execute( "export", "callingcard=$cardinfo->{number}" );
        }
        else {
            $session->execute( "export", "cardnumber=$cardinfo->{cardnumber}" );
            $session->execute( "export", "callingcard=$cardinfo->{cardnumber}" );
        }
        $session->execute( "export", "pin=$cardinfo->{pin}" );
        if ( $whatnow == 1 ) {
            $session->execute( "export", "newcall=1" );
            $session->execute( "export", "destination=$stats{destination}" );
            &exit_program();
        }
        elsif ( $whatnow == 2 ) {
            $session->execute( "export", "newcall=1" );
            $session->execute( "export", "destination=" );
            &exit_program();
        }
        elsif ( $whatnow == 3 ) {
            $session->streamFile( $sound->{goodbye} );
        }
        else {
            $retries++;
        }
    }
    if ( $retries == 3 ) {
        $session->streamFile( $sound->{goodbye} );
    }

}

sub exit_program() {
    $stats{total_time} = tv_interval( $stats{start_time} );
    $astpp_db->do(
"INSERT INTO callingcard_stats(uniqueid,total_time,billable_time) VALUES ("
          . $astpp_db->quote( $stats{uniqueid} ) . ","
          . $astpp_db->quote( $stats{total_time} ) . ","
          . $astpp_db->quote( $stats{answered_time} )
          . ")" );
    $stats{total_time} = tv_interval( $stats{start_time} );
    return 1;
}

sub print_console()    #Dump string to the console
{
    my ($output) = @_;
#    $session->consoleLog( "ASTPP", $output . "\n" );
    print STDERR "ASTPP:" . $output . "\n";
}

################# Program Starts Here #################################
my ( $cardnum, $pin, $destination, $connectsurcharge, $perminsurcharge, $brand )
  = @ARGV;
  
#Defined more variableds ($ani_number,  $aniinfo, $accinfo) for CC ANI Authentication 
my ( $retries, $cardinfo, $numberinfo, $pricelistinfo, @outboundroutes,
    $callstart, $ani_number,  $aniinfo, $accinfo);
$session->answer();
&initialize;
my $vars = $session->getVariable("answered_time");
$vars .= " : ";
$vars .= $session->getVariable("hangup_time");
$ASTPP->debug( debug => "Vars: " . $vars );
return 1 if ( !$session->ready() );

$cardnum = $session->getVariable("callingcard_number");

# If cc_ani_auth=1 means calling card ANI authentication is enabled. 
if($config->{cc_ani_auth}==1 && $cardnum=='')
{
    $ASTPP->debug(
        debug     => "ANI based authentication",
        verbosity => $verbosity
    );
    $ani_number = $session->getVariable("caller_id_number");    
    $aniinfo = &get_ani_map( $astpp_db, $ani_number, $config );    
    $accinfo = &get_account($astpp_db,$aniinfo->{account},'0');    
    $cardinfo = &get_cardnumber( $astpp_db, $accinfo->{cc},$accinfo->{number}, $config );    
    $cardnum = $cardinfo->{cardnumber};
    $cardinfo->{pin} = 'NULL';    
}
######################################

if ( $cardnum && $cardnum > 0 ) {
    $ASTPP->debug(
        debug     => "We recieved a cardnumber from the dialplan",
        verbosity => $verbosity
    );
    $cardinfo = &get_callingcard( $astpp_db, $cardnum, $config );
    if ( !$cardinfo ) {
        $cardinfo = &get_account_cc( $astpp_db, $cardnum );
        $cc = 1 if $cardinfo;
    }
}
else {    #We won't play the welcome file when we already have card numbers.
    $session->streamFile( $config->{calling_cards_welcome_file} );
}

# If $cc == 1 means that we are using an ASTPP account instead of an actual
# calling card.
if ( $cardinfo->{status} != 1 || !$cardinfo->{status} ) {
    $retries = 0;
    while ( $cardinfo->{status} != 1 && $retries < $config->{card_retries} ) {
        $cardnum = $session->playAndGetDigits(
            $config->{cardlength},
            $config->{cardlength},
            1,
            $config->{calling_cards_number_input_timeout},
            "#",
            "$sound->{cardnumber}",
            "",
            '^[0-9]+$'
        );
        $cardinfo = &get_callingcard( $astpp_db, $cardnum, $config );
        if ( !$cardinfo ) {
            $cardinfo = &get_account_cc( $astpp_db, $cardnum );
            $cc = 1 if $cardinfo;
        }
        $ASTPP->debug(
            debug => "CARD BRAND: $cardinfo->{brand} SPECIFIED BRAND: $brand",
            verbosity => $verbosity
        );
        if ( $brand && $brand ne "" ) {
            $cardinfo = "" if $cardinfo->{brand} ne $brand;
        }
        $ASTPP->debug(
            debug     => "ASTPP Number: $cardnum ",
            verbosity => $verbosity
        );
        $ASTPP->debug(
            debug     => "ASTPP Number Status: $cardinfo->{status}",
            verbosity => $verbosity
        );
        if ( $cardinfo->{status} != 1 ) {
            $session->streamFile( $sound->{cardnumber_incorrect} );
        }
        $retries++;
    }
    if ( $cardinfo->{status} != 1 ) {
        $session->streamFile( $sound->{goodbye} );
#        $session->hangup();
        return 1;
    }
}

if ( $pin != $cardinfo->{pin} ) {
    $retries = 0;
    while ( $cardinfo->{pin} != $pin && $retries < $config->{pin_retries} ) {
        $pin = $session->playAndGetDigits(
            $config->{pinlength}, $config->{pinlength},
            1,                    $config->{calling_cards_pin_input_timeout},
            "#",                  "$sound->{pin}",
            "",      '^[0-9]+$'
        );
        if ( $cardinfo->{pin} != $pin ) {
            $session->streamFile( $sound->{pin_incorrect} );
        }
        $retries++;
    }
    if ( $pin != $cardinfo->{pin} ) {
        $session->streamFile( $sound->{pin_incorrect} );
        $session->streamFile( $sound->{goodbye} );
        return 1;
    }
}
&check_card($cardinfo) if $cc == 0;
my $balance = &say_balance($cardinfo);

# Getting this far means we have a valid card and pin.
$brandinfo = &get_cc_brand( $astpp_db, $cardinfo->{brand} ) if $cc == 0;
if ( $brandinfo->{reseller} ) {
    $config =
      &load_config_db_reseller( $astpp_db, $config, $brandinfo->{reseller} );
}
$config = &load_config_db_brand( $astpp_db, $config, $cardinfo->{brand} );
#$config->{debug} = 1;
print STDERR "CC: " . $cc ."\n" if $config->{debug} == 1;
if ($cc == 0) {
	$pricelistinfo = &get_pricelist( $astpp_db, $brandinfo->{pricelist} );
	if ( $brandinfo->{reseller} ne "" ) {
		print STDERR "SETTING ACCOUNTCODE TO: RESELLER " . $brandinfo->{reseller} . "\n" if $config->{debug} == 1;
		$cardinfo->{accountcode} = $brandinfo->{reseller};	
	} else {
		print STDERR "SETTING ACCOUNTCODE TO: SYSTEM DEFAULT " . $config->{callout_accountcode} . "\n" if $config->{debug} == 1;
		$cardinfo->{accountcode} = $config->{callout_accountcode};
	}
} elsif ($cc == 1) {
	$pricelistinfo = &get_pricelist( $astpp_db, $cardinfo->{pricelist} );
	print STDERR "SETTING ACCOUNTCODE TO: ASTPP ACCOUNT " . $cardinfo->{number} . "\n" if $config->{debug} == 1;
	$cardinfo->{accountcode} = $cardinfo->{number};
}
if ( $destination && $destination ne "" ) {
    $numberinfo =
      &get_route( $astpp_db, $config, $destination, $brandinfo->{pricelist},
        $cardinfo )
      if $cc == 0;
    $numberinfo =
      &get_route( $astpp_db, $config, $destination, $cardinfo->{pricelist},
        $cardinfo )
      if $cc == 1;
}
$retries = 0;
while ( !$numberinfo->{pattern} && $retries < $config->{number_retries} ) {
    $destination =
      $session->playAndGetDigits( 4, 35, 1,
        $config->{calling_cards_dial_input_timeout},
        "#", "$sound->{destination}", "", '^[0-9]+$' );
    $numberinfo =
      &get_route( $astpp_db, $config, $destination, $brandinfo->{pricelist},
        $cardinfo );
    if ( !$numberinfo->{pattern} ) {
        $session->streamFile( $sound->{destination_incorrect} );
    }
    else {
	$ASTPP->debug( debug => "COST: " . $numberinfo->{cost});
        $numberinfo->{cost} = $numberinfo->{cost} + $perminsurcharge
          if $perminsurcharge > 0;
	$ASTPP->debug( debug => "COST: " . $numberinfo->{cost});
	$ASTPP->debug( debug => "CONNECTION: " . $numberinfo->{connectcost});
        $numberinfo->{connectcost} =
          $numberinfo->{connectcost} + $connectsurcharge
          if $connectsurcharge > 0;
	$ASTPP->debug( debug => "CONNECTION: " . $numberinfo->{connectcost});
    }
    $retries++;
}
if ( !$numberinfo->{pattern} ) {
    $session->streamFile( $sound->{destination_incorrect} );
    $session->streamFile( $sound->{goodbye} );
#    $session->hangup();
    &leave($cardinfo);
}

#  Congratulations, we now have a working card,pin, and phone number.
$stats{destination} = $destination;
&tell_cost( $numberinfo, $pricelistinfo, $cardinfo );
my $timelimit =
  &timelimit( $numberinfo, $pricelistinfo, $cardinfo, $destination );
$session->streamFile( $sound->{please_wait_will_connect} )
  if $config->{calling_cards_connection_prompt} == 1;
&dialout(
    $destination,   $timelimit, $numberinfo,
    $pricelistinfo, $cardinfo,  $brandinfo
);

1;

#!/usr/bin/env perl
#
# gamemaster daemon

use strict;
use warnings;
no warnings "redefine";
use Bot::BasicBot;
use DBI;
use story;
require "config.pl";

# Some Basic Settings.
my $irc_server = &config_server();
my $irc_port = &config_port();
my $channel = &config_channel();
my $ssl_enable = &config_ssl();
my $nick = &config_nick();
my $sqlite_db = &config_sqlite_db();

# Setup some objects.
my $dbh = DBI->connect("dbi:SQLite:dbname=$sqlite_db","","");
my $story = story->new();


# MAIN ROUTINE
sub game() {
    my $message = $_[0];
    my $nick = $message->{who};

    # Log  message
    print "log: $nick: $message->{body}\n";

    # Do we recognize this character?
    my $ret = &check_character($nick);
    # This will only work if new character.
    if (defined($ret)) {
        return $ret;
    }

    # We recognized the character, let's grab his base info.
    my $select = $dbh->prepare(
        "SELECT strength, level, exp, fighting FROM
        characters where
        nick = '$nick'"
    );
    $select->execute();
    my ($char_str, $char_lvl, $char_exp, $monster_id) = $select->fetchrow_array();

    # If there is a monster, we can fight it!
    if (defined($monster_id)) {
        # Let's get some info about the monster
        my $select = $dbh->prepare(
            "SELECT name,strength,level FROM
            monsters where
            id = '$monster_id'"
        );
        $select->execute();
        my ($mon_name, $mon_str, $mon_lvl) = $select->fetchrow_array();

        # If they wanted to fight, let them!
        if ($message->{body} =~ /fight/i) {
            my $combat_result = &fight($char_str, $char_lvl, $mon_str, $mon_lvl);
            return $combat_result;
        }

        # Did they not try to fight their assailant?
        else {
            return $story->afraid($nick,$mon_name);
        }
    }

#    return $story->quest($message->{who});
    return "I guess you weren't fighting a monster";
}

# Routine to see if we know a character, or option make a new one.
sub check_character() {
    my $nick = $_[0];

    # Does this nick exist in the DB?
    my $select = $dbh->prepare(
        "SELECT * FROM
        characters where
        nick = '$nick'"
    );
    $select->execute();
    my $select_result = $select->fetch();

    # Normally, yes.
    if ( defined($select_result) ) {
        return undef;
    }

    # But if not, we need to create the new character.
    print "Nick $nick doesn't exist yet. Meet and greet...\n";
    my $insert = $dbh->prepare(
        "INSERT INTO characters
        (nick, strength, level, exp, fighting)
        values (
        '$nick',
        10,
        1,
        0,
        1);"
    );
    $insert->execute();
    # We will send them a welcome message.
    return $story->welcome($nick);
}

sub fight() {
    my ($char_str, $char_lvl, $mon_str, $mon_lvl) = @_;

    # We calculate modifiers - I am using the pfsrd ability score modifierds
    # for inspiration under the OGL.
    #
    # http://www.d20pfsrd.com/basics-ability-scores/ability-scores
    # http://www.d20pfsrd.com/extras/community-use
    # https://en.wikipedia.org/wiki/Open_Game_License
    my $char_str_mod = (($char_str - ($char_str % 2)) - 10) / 2;
    my $mon_str_mod = (($mon_str - ($mon_str % 2)) - 10) / 2;

    # We roll a d20 and add the modifier and the lvl.
    my $char_roll = int(rand(20) + $char_str_mod + $char_lvl);
    my $mon_roll = int(rand(20) + $mon_str_mod + $mon_lvl);

    # Who wins? Tie goes to the character.
    if ($char_roll >= $mon_roll) {
        return "victory";
    }
    else {
        return "failure";
    }
}



##################################
#                                #
#    Basic static setup stuff    #
#                                #
##################################

# Overloading the said function.
sub Bot::BasicBot::said {
    my ($self, $message) = @_;
    my $address = $message->{address};

    # Just for fun.
    if ($message->{body} =~ /rpg/) {
        return "I LOVE RPG's!";
    }

    # Are you talking to me!?
    if ($address && $address eq "$nick") {
        return &game($message);
    }

    # Ignore all else.
    return undef;
}

# Just to change what happens when somebody sends the bot "help"
sub Bot::BasicBot::help {
    my $message = "I am the Game Master! " .
    "Feel free to message me and you can get started on your mighty quest! " .
    "See more about me here: https://github.com/mstathers/gamemaster";
    return $message;
}

# Some pre-flight checks - this will create the schema.
sub check_db() {
    # Does the table exist in the DB?
    my $select = $dbh->prepare(
        "SELECT * FROM
        sqlite_master where
        name = 'characters'"
    );
    $select->execute();
    my $select_result = $select->fetch();

    # Normally, yes.
    if ( defined($select_result) ) {
        print "DB exists.\n";
        return 1;
    }

    # If not, we will create the schema.
    print "DB does not exist yet or is broken. Creating...\n";
    if (! -f "gm_schema") {
        die "file gm_schema doesn't exist, cannot create DB\n";
    }

    # This allows us to preload some monsters and more easily
    # manage db schema.
    #
    # TODO Currently very "hacky".
    my $sqlite_cmd_output = `sqlite3 $sqlite_db < gm_schema`;
    if ($sqlite_cmd_output =~ /Error/){
        print "$sqlite_cmd_output\n";
        `rm $sqlite_db`;
        exit 
    }
}

# $bot object constructor.
my $bot = Bot::BasicBot->new(
    server => "$irc_server",
    port => "$irc_port",
    ssl => "$ssl_enable",
    channels => ["$channel"],
    nick => "$nick",
);

# Actually get started.
&check_db();
$bot->run();

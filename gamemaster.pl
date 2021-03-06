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
        nick = ?"
    );
    $select->execute($nick);
    my ($char_str, $char_lvl, $char_exp, $monster_id) = $select->fetchrow_array();

    # If there is a monster, we can fight it!
    if (defined($monster_id)) {
        # Let's get some info about the monster
        my $select = $dbh->prepare(
            "SELECT name,strength,level FROM
            monsters where
            id = ?"
        );
        $select->execute($monster_id);
        my ($mon_name, $mon_str, $mon_lvl) = $select->fetchrow_array();

        # If they wanted to fight, let them!
        if ($message->{body} =~ /fight/i) {
            my $combat_result = &fight($char_str, $char_lvl, $mon_str, $mon_lvl);
            
            # This enemy is finished, win or lose.
            &reset_monster($nick);

            # How did they do?
            if ($combat_result =~ /victory/) {
                my $new_level = &calc_exp($nick, $char_lvl, $mon_lvl);
                return $story->victory($nick,$mon_name,$new_level);
            }
            if ($combat_result =~ /defeat/) {
                return $story->defeat($nick,$mon_name);
            }
        }

        # If the character decides to flee the battle!
        if ($message->{body} =~ /flee/i) {
            # You ran away, you are no longer fighting the monster.
            &reset_monster($nick);

            return $story->flee($nick,$mon_name);
        }

        # did they just do something besides attack or flee from their
        # monster?
        return $story->waiting($nick,$mon_name);
    }

    return &new_quest($nick);
}

# Routine to see if we know a character, or option make a new one.
sub check_character() {
    my $nick = $_[0];

    # Does this nick exist in the DB?
    my $select = $dbh->prepare(
        "SELECT * FROM
        characters where
        nick = ?"
    );
    $select->execute($nick);
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
        ?,
        10,
        1,
        0,
        1);"
    );
    $insert->execute($nick);
    # We will send them a welcome message.
    return $story->welcome($nick);
}

# routine to determine the victor of a fight.
sub fight() {
    my ($char_str, $char_lvl, $mon_str, $mon_lvl) = @_;

    # We calculate modifiers - I am using the pfsrd ability score modifiers
    # for inspiration under the OGL.
    #
    # http://www.d20pfsrd.com/basics-ability-scores/ability-scores
    # http://www.d20pfsrd.com/extras/community-use
    # https://en.wikipedia.org/wiki/Open_Game_License
    my $char_str_mod = (($char_str - ($char_str % 2)) - 10) / 2;
    my $mon_str_mod = (($mon_str - ($mon_str % 2)) - 10) / 2;

    # We roll a d20 and add the modifier the lvl..
    my $char_roll = int(rand(20) + $char_str_mod + $char_lvl);
    my $mon_roll = int(rand(20) + $mon_str_mod + $mon_lvl);

    # Who wins? Tie goes to the character.
    if ($char_roll >= $mon_roll) {
        return "victory";
    }
    else {
        return "defeat";
    }
}

# Reset a monster so that a character is no longer fighting.
sub reset_monster() {
    my ($nick) = @_;

    my $update = $dbh->prepare(
        "UPDATE characters
        SET fighting = null
        where nick = ?"
    );
    $update->execute($nick);
    return undef;
}


# Used to calculate EXP. We we use the difference in levels to do this:
#
#    y=(1.11^x)*50
#
# It should close to 50 exp, depending on the difference.
#
##################################################
#We also calculate level-ups here!
#
#    y=(x^.5/75^.5)+1
#
# It looks a bit like this:
#
# lvl  |  exp
# ------------
#   1  |    0
#   2  |   75
#   3  |  300
#   4  |  675
#     etc
#
sub calc_exp() {
    my ($nick, $char_lvl, $mon_lvl) = @_;

    # we need the difference first
    my $lvl_diff = int($mon_lvl - $char_lvl);
    # we can the calculate.
    my $exp_gain = int((1.11 ** $lvl_diff)*50);

    # We need to update the character's EXP in the DB.
    my $update = $dbh->prepare(
        "UPDATE characters
        SET exp = exp + ?
        where nick = ?"
    );
    $update->execute($exp_gain, $nick);


    # We also need to see if they leveled up!
    my $select = $dbh->prepare(
        "SELECT exp FROM
        characters where
        nick = ?"
    );
    $select->execute($nick);
    my ($char_exp) = $select->fetchrow_array();

    # Calculate what the character's level should be.
    my $new_level = int((($char_exp ** .5) / (75 ** .5)) + 1);
    
    # Did they go up a level?
    if ($new_level > $char_lvl) {
        my $update = $dbh->prepare(
            "UPDATE characters
            SET level = ?
            where nick = ?"
        );
        $update->execute($new_level, $nick);

        # We need to pass back if we level up.
        return "$new_level";
    }

    # We can be quiet.
    return undef;
}


sub new_quest() {
    my ($nick) = @_;

    # How many monsters do we have?
    my $select = $dbh->prepare(
        "SELECT id FROM
        monsters WHERE
        id = (SELECT MAX(id) FROM
        monsters)"
    );
    $select->execute();
    my ($monster_max_id) = $select->fetchrow_array();

    # Random monster id. This is +1 because we don't want zero.
    my $random_monster = int(rand($monster_max_id) + 1);

    # we need to save to the db that this monster is fighting the
    # character.
    my $update = $dbh->prepare(
        "UPDATE characters
        SET fighting = ?
        where nick = ?"
    );
    $update->execute($random_monster, $nick);

    # Let's get some info about the monster
    $select = $dbh->prepare(
        "SELECT name FROM
        monsters where
        id = ?"
    );
    $select->execute($random_monster);
    my ($mon_name) = $select->fetchrow_array();

    # SQL to determine the total number of adjectives in the table.
    my $select = $dbh->prepare(
        "SELECT id FROM
        adjectives WHERE
        id = (SELECT MAX(id) FROM
        adjectives)"
    );
    $select->execute();
    my ($adjective_max_id) = $select->fetchrow_array();

    # Randomly pick an adjective.
    my $random_adjective = int(rand($adjective_max_id) + 1);
    $select = $dbh->prepare(
        "SELECT adjective FROM
        adjectives where
        id = ?"
    );
    $select->execute($random_adjective);
    my ($monster_adjective) = $select->fetchrow_array();

    # Let the player know what adjective + monster they will be 'fight'-ing
    return $story->new_quest($nick, $monster_adjective, $mon_name);
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

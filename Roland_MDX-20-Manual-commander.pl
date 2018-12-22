#!/usr/bin/perl

our $VERSION='0.20130119';	# Please use format: major_revision.YYYYMMDD[hh24mi]

=head1 NAME

Roland_MDX-20-Manual-commander.pl - Allows you to move, cut, and measure using a Windows Joystick and your Roland MDX-20 (or other RML-1 compatible milling machine)

=head1 SYNOPSIS

bfxgen.pl - Puts a CSV file worth of text into graphics.

     Options:
       -c		specify the com port the milling maching is connected to. eg: com1
			if omitted, the first com port that can be sucessfully opened is assumed to be your plotter
       -j		specify which joystick to use (in case you've got more than 1)
			if omitted, the first joystick found (number zero) is assumed to be the one to use
       -r		max step rate	   (eg: 100) - max number of steps to move at full joystick swing
       -d		delay milliseconds (eg: 100) - number of miliseconds to wait after sending a move command
       -help		brief help message
       -man		full documentation

=cut
######################################################################

use strict;
#use warnings;		# same as -w switch above
use Getopt::Long;	# Commandline argument parsing
use Pod::Usage;		# Inbuilt documentation helper
use Win32::API;		# for joystick control
#use Win32::SerialPort;	# to write to the plotter
use Math::Trig;		# PI
use constant PI    => 4 * atan2(1, 1);


my %arg;&GetOptions(	# Parse options and store copies into the %arg hash
  'help|?' => \$arg{'help'},	# breif instructions
  'man' => \$arg{'man'},	# complete manual
  'c=s'	=> \$arg{'c'},		# COM port to use
  'j=s'	=> \$arg{'j'},		# joystick to use
  'r=i'	=> \$arg{'r'},		# rate
  'd=i'	=> \$arg{'d'},		# delay
) or &pod2usage(2); 
no warnings;
  &pod2usage(1) if ($arg{'help'});
  &pod2usage(-exitstatus => 0, -verbose => 2) if $arg{'man'};
#use warnings;

my $lastp='';
my ($joyinfoex,$joyGetPosEx);	# joystick structure and data call
my ($midl,$midh)=(32768-7500,32768+7500);	# joystick center limits
my ($range)=$midl + (65535-$midh);
my $rate=$arg{'r'} || 45;	# max number of steps to move at full joystick swing
my $delay=$arg{'d'}/1000||0.02;	# number of miliseconds to wait after sending a move command - .02 is smallest sensible amount @ 9600baud
my $port;			# serial port handle.
my %state;			# current(last) button state
my %buthead=qw( 1 A 2 B 4 X 8 Y 16 left 32 right 64 back 128 start);
my($x,$y,$z)=(0,0,0);		# Starting plotter coordinates
my @buf;			# playback buffer


# $arg{'compress'}=4 unless($arg{'compress'});

print "Use joysticks & dpad to move. A=cut, X=off, B=reset, 'back'=exit\n";


######################################################################

$port=&setup_serial2();	# Find the plotter
die "Could not open serial port" unless($port);

&countdevs();		# check the joystick support

&setupjoystick();	# load $joyinfoex,$joyGetPosEx

&showret($joyinfoex,&getjoy($joyinfoex)); # Show a demo return value;

&waitcenter();		# pause until they center the joystick - don't want the tool going nuts immediately!

# print "joyGetPosEx="; my $ret=$joyGetPosEx->Call($arg{'j'} || 0,$joyinfoex); print "$ret\n";

while(1) {
  my $rc=&getjoy($joyinfoex);	# 0 means OK.
  if($rc!=0) {
    &mdxreset();
    die "Joystick problem: $rc";
  }
  my ($d,$e)=&showret($joyinfoex,$rc);

  # what new things just came in from the joystick?
  my($m,$v,$in,$c);
  foreach my $event (@{$e}) {

    if($event eq 'back') {	# exit
      $port->close if(ref $port);
      print "You hit the 'back' button, which ends this program now\n";
      &write_serial2(";;^IN;!MC0;\r\n");	# reset
      exit(0);
    }

    if($event eq 'B') {		# reset
      &write_serial2(";;^IN;!MC0;\r\nV15.0;\r\n");	# 15 is full speed
    }

    if($event eq 'A') {		# motor on
      &write_serial2("^PR;^PA;\r\n!MC1;\r\nZ$x,$y,$z;\r\n"); # Z-40,-40,40;\r\n");	
      # &write_serial2("^PR;Z$x,$y,$z;^PA;\r\n!MC1;\r\nZ$x,$y,$z;\r\n"); # Z-40,-40,40;\r\n");	
    }

    if($event eq 'X') {		# motor off
      &write_serial2("!MC0;\r\n");
    }

    if($event eq 'Y') {		# keyboard mode
      print "Fine steps?  Not done\n";
    }

    if($event eq 'left') {		# keyboard mode
      &keyboard_mode();
    }

    if($event eq 'start') {	# recording playback
      &playback_buf($x,$y,$z);
    }

    if($event eq 'dwPOV') {	# Micro movement
      $in=$d->{$event};
      $y++ if($in==0);
      $y-- if($in==18000);
      $x++ if($in==9000);
      $x-- if($in==27000);
      $c++;
    }

  } # events


  $v='dwXpos'; $m=0; $in=$d->{$v}; $m=$in-$midh+$midl if($in>$midh); $m=$in+1 if($in<$midl); if($m){ $m-=($range/2); $m=$m/$range*$rate; $x+=$m; $c++; print "$v $m\n"}
  $v='dwYpos'; $m=0; $in=$d->{$v}; $m=$in-$midh+$midl if($in>$midh); $m=$in+1 if($in<$midl); if($m){ $m-=($range/2); $m=$m/$range*$rate; $y-=$m; $c++; print "$v $m\n"}
  $v='dwRpos'; $m=0; $in=$d->{$v}; $m=$in-$midh+$midl if($in>$midh); $m=$in+1 if($in<$midl); if($m){ $m-=($range/2); $m=$m/$range*$rate; $z-=$m; $c++; print "$v $m\n"}

  if($c) {
    $x=int($x); $y=int($y); $z=int($z);
    $x=0 if($x<0); $y=0 if($y<0);
    print "x=$x; y=$y, z=$z;\n";
    $x=8136 if($x>8136); $y=6096 if($y>6096);
    &write_serial2("Z$x,$y,$z;\r\n");
    if($delay>0) { select(undef, undef, undef, $delay); } 
  }

} # main loop


sub keyboard_mode {
  print "Place what into the playback buffer?\n";
  print "\tC - circle\n";
  print "\tQ - quit menu (nothing changed)\n";
  my $choice=<STDIN>; chomp($choice);
  if($choice=~/c/i) { # circle
    print "Enter ellipse (circle) dimensions [cuts clockwise from 12]:\n";
    print "X diameter mm, Y diameter mm, CuttingSpeed (15=max):  eg: 30,30,15.0 \n";
    my $in=<STDIN>; chomp($in);
    my($xdia,$ydia,$spd)=($in=~/([\d\.]+)\b.+?([\d\.]+)\b.+?([\d\.]+)/);
    if(($xdia>0)&&($ydia>0)&&($spd>0)) {
      &add_circle($xdia,$ydia,$spd);
    } else {
      print "Ignorred dud input: '$in'\n";
    }
  } # circle

} # keyboard_mode
  


sub playback_buf {
  my($sx,$sy,$sz)=@_;
  my $lspd=-9999;

  print "Playing " . (1+$#buf) . " commands...\n";
  foreach my $pdat (@buf) {
    my($bx,$by,$bspd)=@{$pdat};
    if($bspd!=$lspd){$lspd=$bspd; &write_serial2("V$bspd;\r\n");}      # 15 is full speed
    my $gox=int($sx+$bx);
    my $goy=int($sy+$by);
    my $goz=int($sz);
    $gox=0 if($gox<0); $goy=0 if($goy<0);
    $gox=8136 if($gox>8136); $goy=6096 if($goy>6096);
    print "x=$gox; y=$goy, z=$goz;\n";
    &write_serial2("Z$gox,$goy,$goz;\r\n");
    # if($delay>0) { select(undef, undef, undef, $delay/10); } 		# these will be micro-commands; delay a lot less...
  }
  print "Played " . (1+$#buf) . " commands...\n";
} # playback_buf



sub add_circle {	# nb: these are all relative commands (added to current x and y)
  my($xdia,$ydia,$spd)=@_;

  my $from=0;
  my $to=360;
  my $d2r=180/PI;
  my $pts=0;
  @buf=();

  my $xsize=$xdia*40;			# circle circumference in printer units
  my $xmid=0; #($xsize/2);		# draw from existing X
  my $ysize=$ydia*40;
  my $ymid=($ysize/2);			# and middle of Y
  my ($lastx,$lasty)=(-99999,-99999);	# impossible starting values)
  my $step=$to/(PI*($xsize+$ysize));	# resolution of circle

  for(my $i=$from;$i<=$to;$i+=$step) {

  #  my $xc=cos(($i-90)/$d2r)/2;
  #  my $yc=sin(($i+180)/$d2r)/2;

    my $xc=cos((-($i-90))/$d2r)/2;
    my $yc=sin(($i-90)/$d2r)/2;


    my $x=int($xmid + ($xc*$xsize));
    my $y=-int($ymid + ($yc*$ysize));	# - for clockwise

    if(($x!=$lastx)||($y!=$lasty)) {	# Skipe dupes
      push @buf,[$x,$y,$spd];		# Buffer this
      $pts++;
      $lastx=$x;$lasty=$y;
    }

    # &draw_line($this, [$x,$y,$x,$y], "black");	# A dot

    print sprintf("%6.4f %6.4f\t$x\t$y\n", $xc,$yc);
  }

  print "Added $pts points (${xdia}mm X, ${ydia} Y, speed=$spd)\n";
} # add_circle



=for code

dwSize dwFlags dwXpos dwYpos dwZpos dwRpos dwUpos dwVpos dwButtons dwButtonNumber dwPOV dwReserved1 dwReserved2
0      1       2      3      4      5      6      7      8         9      

Left Thumbstick: (Pan tool)
 (Y direction) inwards		4/0=up, 65535=down, 30000-40000=mid
 (X direction) left		3/0=left
 (X direction) right		3/65536
 (Y direction) outwards		4/65536

Directional Pad (D-Pad)		65535(none), 0,4500 9000,13500 18000,22500 27000,31500
 Same as Left Thumstick
 (Pan X/Y), in small steps

Right Thumbstick: (Raise/Lower tool)
 Tool Up (Z direction)		6/0=up		28000-35000=mid
 Tool Down  (Z dir.)		6/65535=down

Button Functions:
 Y: fine-steps mode		9/8
 X: Motor Off			9/4
 B: Reset (motor off+up)	9/2
 A: Motor On			9/1
 Back:  exit			9/64 & 10=1
 Start: playback a recording	9/128 & 10=1

Left Shoulder button:
 activate keyboard control	9/16
	(right=32)

=cut











######################################################################

=for fails

sub setup_serial {
  my $portno=($arg{'c'}=~/(\d+)/) if(defined $arg{'c'});
  my @portlist=($portno);
  @portlist=(0..33) unless(defined $portno);

  foreach my $p (@portlist) {
    my $port = Win32::SerialPort->new("COM$p");	 # this fails sometimes, when plain "open" works
    if($port) {
if(0) { # this mucks up the port:-
      $port->baudrate(9600);
      $port->parity("none");
      $port->handshake("rts");
      $port->databits(8);
      $port->stopbits(1);
      $port->read_char_time(0);
      $port->read_const_time(1);
}
      print "Opened COM$p sucessfully.\n";
      return $port;
    } else {
      print "Cannot open COM$p: $!\n";
    }
  }
  return $port;
} # setup_serial

sub write_serial {
  my($what)=@_;
  $port->write($what);
  print "MDX-20: $what\n";
  # $port->close;
}

=cut

sub setup_serial2 {
  my $portno=($arg{'c'}=~/(\d+)/) if(defined $arg{'c'});
  my @portlist=($portno);
  @portlist=(0..33) unless(defined $portno);

  foreach my $p (@portlist) {
    my $rc=open(SER,'>',"COM$p:");
    if($rc) {
      print "Opened COM$p sucessfully.\n";

	my $old_fh = select(SER);
	$| = 1;		# set autoflush
	select($old_fh);

      return $rc;
    } else {
       print "Cannot open COM$p: $!\n";
    }
  } # portlist
  return undef;
} # setup_serial2

sub write_serial2 {
  my($what)=@_;
  print SER $what;
  print "MDX-20: $what\n";
}


# pause until they center the joystick - don't want the tool going nuts immediately!
sub waitcenter {
  my $centered=0;
  my $p='';
RECENTER:
  while(!$centered) {
    my $rc=&getjoy($joyinfoex);	# 0 means OK.
    my ($d,$e)=&showret($joyinfoex,$rc,$p);
    if($rc==0) {	# OK
      $centered=1 if( 
	( $d->{'dwButtonNumber'}==0 ) &&
	( $d->{'dwButtons'}==0 ) &&
	( $d->{'dwPOV'}==65535 ) &&

	( $d->{'dwXpos'}>$midl ) &&
	( $d->{'dwXpos'}<$midh ) &&

	( $d->{'dwYpos'}>$midl ) &&
	( $d->{'dwYpos'}<$midh ) &&

	( $d->{'dwRpos'}>$midl ) &&
	( $d->{'dwRpos'}<$midh ) 
      );
      if(!$centered) {
	$p="Please center all your joystick controls to continue...";
      } else { $p=''; }
    }
  } # centered

  &debounce(8,'orange Y','Press the %s button to begin...');


}

sub debounce {
  my($butn,$butdesc,$msg)=@_;
  my $p='';
  my $continue=0;

  # wait for press
  while(!$continue) {
    my $rc=&getjoy($joyinfoex);	# 0 means OK.
    my ($d,$e)=&showret($joyinfoex,$rc,$p);

    if($rc==0) {	# OK
      $continue=1 if( 
	( $d->{'dwButtonNumber'}==1 ) &&
	( $d->{'dwButtons'}==$butn )
      );
    }
    $p=sprintf($msg,$butdesc);
  } # continue

  my $ret=0; $p="To continue, now release $butdesc";

  # wait for release
  while(!$ret) {
    my $rc=&getjoy($joyinfoex);	# 0 means OK.
    my ($d,$e)=&showret($joyinfoex,$rc,$p);

    if($rc==0) {	# OK
      $ret=1 if( 
	( $d->{'dwButtonNumber'}==0 ) &&
	( $d->{'dwButtons'}==0 )
      );
    }
  } # return now
} # debounce


sub getjoy {
  my($joyinfoex)=@_;
  my $ret=$joyGetPosEx->Call($arg{'j'} || 0,$joyinfoex) . ' ';
  # my $ret=$joyGetPosEx->Call($arg{'j'} || 0,$joyinfoex) . ' ';
  return $ret;
}

sub countdevs {
  # How many joysticks does the driver support?
  my $joyGetNumDevs=Win32::API->new('WinMM', 'int joyGetNumDevs()');
  die "Win32 problem - cannot call 'joyGetNumDevs'" unless(ref $joyGetNumDevs);
  print "joyGetNumDevs="; my $numj=$joyGetNumDevs->Call(); print "$numj\n";
}

sub showret {
  my($joyinfoex,$rc,$msg)=@_;
  my $p=''; my %d; my @e;
  if($rc!=0) {
    $p.="Error code: $rc encountered. ";
    $p.='(This means: joystick not connected) ' if($rc==165);
  } else {
    foreach my $i (qw( dwSize dwFlags dwXpos dwYpos dwZpos dwRpos dwUpos dwVpos dwButtons dwButtonNumber dwPOV dwReserved1 dwReserved2 )) {
      my $j=$joyinfoex->{$i};
      push @e,$i if($state{$i}!=$j);
      $d{$i}=$j;
      $p.=$j . ' ';
    }
    foreach my $k (keys %buthead) {
      if($d{'dwButtons'}&$k) {
	$p.=$buthead{$k} . ' ';
	push @e,$buthead{$k} unless($state{'dwButtons'}&$k);
      }
    }
  }
  $p.="\n$msg" if((defined $msg)&&($msg ne ''));
  print "$p\n" unless($p eq $lastp);
  #print "dwB=$d{'dwButtonNumber'} p=$p\n" unless($p eq $lastp);
  $lastp=$p;
  %state=%d;	# remember last state
  return \%d,\@e;
} # showret


sub setupjoystick {

# Define the structure we need to get all this info (might already be defined in Win32::API - I didn't look)
  typedef Win32::API::Struct JOYINFOEX => (
    'LONG', 'dwSize',		# size of structure        
    'LONG', 'dwFlags',		# flags to indicate what to return        
    'LONG', 'dwXpos',		# x position  L/R of LHS joystick      
    'LONG', 'dwYpos',		# y position  U/D of LHS joystick      
    'LONG', 'dwZpos',		# z position  L-Trigger(32767=>65408). R-Trigger (32767=>128)
    'LONG', 'dwRpos',		# rudder/4th axis position L/R RHS joystick
    'LONG', 'dwUpos',		# 5th axis position        U/D RHS joystick
    'LONG', 'dwVpos',		# 6th axis position        ?
    'LONG', 'dwButtons',	# button states        
    'LONG', 'dwButtonNumber',	# current button number pressed        
    'LONG', 'dwPOV',		# point of view state        
    'LONG', 'dwReserved1',	# reserved for communication between winmm driver        
    'LONG', 'dwReserved2',	# reserved for future expansion
  );

  $joyinfoex=Win32::API::Struct->new( 'JOYINFOEX' ); # Register the structure

  # Windows wants us to fill in some parts of the structure before we use it:
  $joyinfoex->{dwSize}=Win32::API::Struct::sizeof($joyinfoex);
  $joyinfoex->{dwFlags}= 0x01 |  0x02 |  0x04 |  0x08 |  0x10 |  0x20 |  0x40 |  0x80; # JOY_RETURNX JOY_RETURNY JOY_RETURNZ JOY_RETURNR JOY_RETURNU JOY_RETURNV JOY_RETURNPOV JOY_RETURNBUTTONS

  # "import" the call we need to get the joystick data.
  $joyGetPosEx=Win32::API->new('WinMM', 'int joyGetPosEx(int a, JOYINFOEX *p)');
} # setupjoystick


sub details {
  my($joyinfoex)=@_;

#if($ret!=0) {
#  print "non-zero return code means some kind of error.\n";
#  print "if it's 165 - your joystick is probably off or not connected/detected?\n";
#  print "sleeping 5 seonnds...\n";sleep(5);
#}

# Show demo results
print "dwSize=" . $joyinfoex->{ 'dwSize' } . "\n";
print "dwFlags=" . $joyinfoex->{ 'dwFlags' } . "\n";
print "dwXpos=" . $joyinfoex->{ 'dwXpos' } . "\n";
print "dwYpos=" . $joyinfoex->{ 'dwYpos' } . "\n";
print "dwZpos=" . $joyinfoex->{ 'dwZpos' } . "\n";
print "dwRpos=" . $joyinfoex->{ 'dwRpos' } . "\n";
print "dwUpos=" . $joyinfoex->{ 'dwUpos' } . "\n";
print "dwVpos=" . $joyinfoex->{ 'dwVpos' } . "\n";
print "dwButtons=" . $joyinfoex->{ 'dwButtons' } . "\n";
print "dwButtonNumber=" . $joyinfoex->{ 'dwButtonNumber' } . "\n";
print "dwPOV=" . $joyinfoex->{ 'dwPOV' } . "\n";
print "dwReserved1=" . $joyinfoex->{ 'dwReserved1' } . "\n";
print "dwReserved2=" . $joyinfoex->{ 'dwReserved2' } . "\n";

print "If you don't see numbers above, your joystick isn't connected or turned on...\n";
print "looping in 2 seconds...\n";
sleep(2);

}

=pod here

=head1 DESCRIPTION

B<This program> lets you use your joystick to manually control a CNC milling machine (i.e. plotter), like an MDX-20

When first run, it will attempt to auto-find your plotter and joystick, and issue a reset to your plotter.

Use the following joystick movements to control your machine:

=begin html

<p><center><img src="http://www.chrisdrake.com/airfoil/Roland_MDX-20-Manual-commander600x400.jpg" width="600" height="400" alt="Controller button layout" /></center></p>

=end html

Left Thumbstick: (Pan tool)
 (Y direction) inwards
 (X direction) left
 (X direction) right
 (Y direction) outwards

Directional Pad (D-Pad)
 Same as Left Thumstick
 (Pan X/Y), in small steps

Right Thumbstick: (Raise/Lower tool)
 Tool Up (Z direction)
 Tool Down  (Z dir.)

Button Functions:
 Y: fine-steps mode
 X: Motor Off
 B: Reset (motor off+up)
 A: Motor On
 Back:  exit
 Start: playback a recording

Left Shoulder button:
 activate keyboard control

=head1 README

Allows you to move, cut, and measure using a Windows Joystick and your Roland MDX-20 (or other RML-1 compatible milling machine)

=head1 PREREQUISITES

Getopt::Long;     
Pod::Usage;       
Win32::API;       

=head1 SCRIPT CATEGORIES

Win32
Win32/Utilities

=head1 AUTHOR

Chris Drake, E<lt>cdrake@cpan.orgE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2013 by Chris Drake

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.10.1 or,
at your option, any later version of Perl 5 you may have available.

=cut


#####


=for MDX-20 Measurement notes

In both X and Y directions, 40 units = 1mm  (10cm=4000)
Maximum extents are:
  x= 0 .. 8136
  y= 0 .. 6096
(going outside these ranges causes the tool to auto-raise.)
  So - maximum cutting size is 203.4mm by 152.4mm



=for RML-1 Notes


Mode 1

;	[Delimiter]		command separator
\s	[special delimiter]	space or tab only
D@!^_	[Command]		(D=any letter)
000	[Paramater]
,	[Delimiter for paramaters]
cr+lf	[Terminator - optional usually]

Mode 2

(similar)

Mode 1+2
!	preceeds a mode-2 command


^	call mode 2
IN;	Initialize, stop tool, move tool up, clear errors
!MC0;	prohibit rotation (waits too I think)
V15.0;	Velocity Z-Axis (mm/sec)
^PR;	Change to relative paramater mode
Z0,0,2420; move to x,y,z (at speed set by V) in whatever coordinate mode was selected
^PA;	Change to absolute paramater mode
!MC1;	makes motor rotate when the tool gets moved



;;^IN;!MC0;
V15.0;^PR;Z0,0,2420;^PA;
!MC1;
Z-40,-40,2420;
Z-40,-40,40;
V1.0;Z-40,-40,-120;
Z1421,-40,-120;
Z1421,551,-120;
Z-40,551,-120;
Z-40,0,-120;
Z251,0,-120;
Z251,0,-119;
Z252,0,-117;
Z254,0,-107;
Z254,0,-106;
Z262,0,-77;
Z263,0,-75;
Z265,0,-72;
Z266,0,-71;
Z269,0,-70;
Z276,0,-67;

Z398,0,-89;
Z398,0,-91;
Z398,0,-92;
Z403,0,-120;
Z1381,0,-120;
Z1381,511,-120;
Z0,511,-120;
Z0,164,-120;
Z0,162,-103;
Z0,161,-92;

Z0,40,-120;
Z81,40,-120;

Z283,271,-71;
Z283,271,-73;
Z281,271,-94;
Z281,271,-95;
Z276,271,-120;
Z240,271,-120;
V15.0;Z240,271,2420;
!MC0;^IN;

=cut

# The end.

package Hydra::Controller::Admin;

use strict;
use warnings;
use base 'Catalyst::Controller';
use Hydra::Helper::Nix;
use Hydra::Helper::CatalystUtils;
use Hydra::Helper::AddBuilds;
use Data::Dump qw(dump);
use Digest::SHA1 qw(sha1_hex);
use Crypt::RandPasswd;
use Sys::Hostname::Long;
use Email::Simple;
use Email::Sender::Simple qw(sendmail);
use Email::Sender::Transport::SMTP;

sub nixMachines {
    my ($c) = @_;
    my $result = "# GENERATED BY HYDRA\n";
	
    foreach my $machine ($c->model("DB::BuildMachines")->all) {
    	if($machine->enabled) {
	        $result = $result . $machine->username . '@'. $machine->hostname . ' ';
	        foreach my $system ($machine->buildmachinesystemtypes) {
	            $result = $result . $system->system .',';
	        }
	        chop $result;
	        $result = $result . ' '. $machine->ssh_key . ' ' . $machine->maxconcurrent . ' '. $machine->speedfactor . ' ' . $machine->options . "\n";
    	}
    }
    return $result;
}

sub saveNixMachines {
    my ($c) = @_;

    die("File not writable: /etc/nix.machines") if ! -w "/etc/nix.machines" ;

    open (NIXMACHINES, '>/etc/nix.machines') or die("Could not write to /etc/nix.machines");
    print NIXMACHINES nixMachines($c);
    close (NIXMACHINES);     
}

sub admin : Chained('/') PathPart('admin') CaptureArgs(0) {
    my ($self, $c) = @_;
    requireAdmin($c);
    $c->stash->{admin} = 1;
}

sub index : Chained('admin') PathPart('') Args(0) {
    my ($self, $c) = @_;
    $c->stash->{machines} = [$c->model('DB::BuildMachines')->search(
        {}, 
        { order_by => ["enabled DESC", "hostname"]
        , '+select' => ["(select bs.stoptime from buildsteps as bs where bs.machine = (me.username || '\@' || me.hostname) and not bs.stoptime is null order by bs.stoptime desc limit 1)"]
        , '+as' => ['idle']
        })];
    $c->stash->{steps} = [ $c->model('DB::BuildSteps')->search(
        { 'me.busy' => 1, 'schedulingInfo.busy' => 1 },
        { join => [ 'schedulingInfo', 'build' ] 
        , order_by => [ 'machine', 'outpath' ]
        } ) ];
    $c->stash->{template} = 'admin.tt';
 }
 
sub updateUser {
    my ($c, $user) = @_;

    my $username     = trim $c->request->params->{"username"};
    my $fullname     = trim $c->request->params->{"fullname"};
    my $emailaddress = trim $c->request->params->{"emailaddress"};
    my $emailonerror = trim $c->request->params->{"emailonerror"};
    my $roles         = $c->request->params->{"roles"} ; 
    
    $user->update(
        { fullname => $fullname
        , emailaddress => $emailaddress
        , emailonerror => $emailonerror
        });
    $user->userroles->delete_all;
    if(ref($roles) eq 'ARRAY') {
        for my $s (@$roles) {
            $user->userroles->create({ role => $s}) ;
        }       
    } else {
        $user->userroles->create({ role => $roles}) if defined $roles ;
    }   
}

sub user : Chained('admin') PathPart('user') CaptureArgs(1) {
    my ($self, $c, $username) = @_;

    requireAdmin($c);

    my $user = $c->model('DB::Users')->find($username)
        or notFound($c, "User $username doesn't exist.");

    $c->stash->{user} = $user;
}

sub users : Chained('admin') PathPart('users') Args(0) {
    my ($self, $c) = @_;
    $c->stash->{users} = [$c->model('DB::Users')->search({}, {order_by => "username"})];

    $c->stash->{template} = 'users.tt';
}

sub user_edit : Chained('user') PathPart('edit') Args(0) {
    my ($self, $c) = @_;

    $c->stash->{template} = 'user.tt';
    $c->stash->{edit} = 1;
}

sub user_edit_submit : Chained('user') PathPart('submit') Args(0) {
    my ($self, $c) = @_;
    requirePost($c);

    txn_do($c->model('DB')->schema, sub {
        updateUser($c, $c->stash->{user}) ;
    });
    $c->res->redirect("/admin/users");
}

sub sendemail {
   my ($to, $subject, $body) = @_; 
   
   my $url = hostname_long;
   my $sender = ($ENV{'USER'} || "hydra") .  "@" . $url;
   
   my $email = Email::Simple->create(
        header => [
            To      => $to,
            From    => "Hydra <$sender>",
            Subject => $subject
        ],
        body => $body
    );

    sendmail($email);
}

sub reset_password : Chained('user') PathPart('reset-password') Args(0) {
    my ($self, $c) = @_;

    # generate password
    my $password = Crypt::RandPasswd->word(8,10);
    
    # calculate hash
    my $hashed = sha1_hex($password);

    $c->stash->{user}-> update({ password => $hashed}) ;

    # send email

    sendemail(
        $c->user->emailaddress, 
        "New password for Hydra",
        "Hi,\n\n".
        "Your password has been reset. Your new password is '$password'.\n".
        "You can change your password at http://".hostname_long."/change-password .\n".
        "With regards, Hydra\n"
    );

    $c->res->redirect("/admin/users");
}

sub machines : Chained('admin') PathPart('machines') Args(0) {
    my ($self, $c) = @_;
    $c->stash->{machines} = [$c->model('DB::BuildMachines')->search({}, {order_by => "hostname"})];
    $c->stash->{systems} = [$c->model('DB::SystemTypes')->search({}, {select => ["system"], order_by => "system" })];
    $c->stash->{nixMachines} = nixMachines($c);
    $c->stash->{nixMachinesWritable} = (-e "/etc/nix.machines" && -w "/etc/nix.machines");

    $c->stash->{template} = 'machines.tt';
 }

sub machine : Chained('admin') PathPart('machine') CaptureArgs(1) {
    my ($self, $c, $machineName) = @_;

    requireAdmin($c);

    my $machine = $c->model('DB::BuildMachines')->find($machineName)
        or notFound($c, "Machine $machineName doesn't exist.");

    $c->stash->{machine} = $machine;
}

sub machine_edit : Chained('machine') PathPart('edit') Args(0) {
    my ($self, $c) = @_;
    $c->stash->{template} = 'machine.tt';
    $c->stash->{systemtypes} = [$c->model('DB::SystemTypes')->search({}, {order_by => "system"})];
    $c->stash->{edit} = 1;
}

sub machine_edit_submit : Chained('machine') PathPart('submit') Args(0) {
    my ($self, $c) = @_;
    requirePost($c);

    txn_do($c->model('DB')->schema, sub {
    	updateMachine($c, $c->stash->{machine}) ;
    });
    saveNixMachines($c);
    $c->res->redirect("/admin/machines");
}

sub updateMachine {
	my ($c, $machine) = @_;

    my $hostname      = trim $c->request->params->{"hostname"};
    my $username      = trim $c->request->params->{"username"};
    my $maxconcurrent = trim $c->request->params->{"maxconcurrent"};
    my $speedfactor   = trim $c->request->params->{"speedfactor"};
    my $ssh_key       = trim $c->request->params->{"ssh_key"};
    my $options       = trim $c->request->params->{"options"};
    my $systems       = $c->request->params->{"systems"} ; 
	
    error($c, "Invalid or empty username.") if $username eq "";
    error($c, "Max concurrent builds should be an integer > 0.") if $maxconcurrent eq "" || ! $maxconcurrent =~ m/[0-9]+/;
    error($c, "Speed factor should be an integer > 0.") if $speedfactor eq "" || ! $speedfactor =~ m/[0-9]+/;
    error($c, "Invalid or empty SSH key.") if $ssh_key eq "";
    	
    $machine->update(
        { username => $username
        , maxconcurrent => $maxconcurrent
        , speedfactor => $speedfactor
        , ssh_key => $ssh_key
        , options => $options
        });
    $machine->buildmachinesystemtypes->delete_all;
    if(ref($systems) eq 'ARRAY') {
	    for my $s (@$systems) {
	        $machine->buildmachinesystemtypes->create({ system => $s}) ;
	    }       
    } else {
        $machine->buildmachinesystemtypes->create({ system => $systems}) ;
    }   
}

sub create_machine : Chained('admin') PathPart('create-machine') Args(0) {
    my ($self, $c) = @_;

    requireAdmin($c);
    
    $c->stash->{template} = 'machine.tt';
    $c->stash->{systemtypes} = [$c->model('DB::SystemTypes')->search({}, {order_by => "system"})];
    $c->stash->{edit} = 1;
    $c->stash->{create} = 1;
}


sub create_machine_submit : Chained('admin') PathPart('create-machine/submit') Args(0) {
    my ($self, $c) = @_;

    requireAdmin($c);
    
    my $hostname = trim $c->request->params->{"hostname"};
    error($c, "Invalid or empty hostname.") if $hostname eq "";
    
    txn_do($c->model('DB')->schema, sub {
        my $machine = $c->model('DB::BuildMachines')->create(
            { hostname => $hostname });
        updateMachine($c, $machine);
    });
    saveNixMachines($c);
    $c->res->redirect("/admin/machines");
}

sub machine_delete : Chained('machine') PathPart('delete') Args(0) {
    my ($self, $c) = @_;
    requirePost($c);

    txn_do($c->model('DB')->schema, sub {
        $c->stash->{machine}->delete;
    });    
    saveNixMachines($c);
    $c->res->redirect("/admin/machines");
}

sub machine_enable : Chained('machine') PathPart('enable') Args(0) {
    my ($self, $c) = @_;
    $c->stash->{machine}->update({ enabled => 1});
    saveNixMachines($c);
    $c->res->redirect("/admin/machines");
}

sub machine_disable : Chained('machine') PathPart('disable') Args(0) {
    my ($self, $c) = @_;
    $c->stash->{machine}->update({ enabled => 0});
    saveNixMachines($c);
    $c->res->redirect("/admin/machines");
}

sub clearfailedcache : Chained('admin') Path('clear-failed-cache') Args(0) {
    my ($self, $c) = @_;

    my $r = `nix-store --clear-failed-paths '*'`;

    $c->res->redirect("/admin");
}

sub clearvcscache : Chained('admin') Path('clear-vcs-cache') Args(0) {
    my ($self, $c) = @_;

    print "Clearing path cache\n";
    $c->model('DB::CachedPathInputs')->delete_all;
    
    print "Clearing git cache\n";
    $c->model('DB::CachedGitInputs')->delete_all;

    print "Clearing subversion cache\n";
    $c->model('DB::CachedSubversionInputs')->delete_all;

    print "Clearing bazaar cache\n";
    $c->model('DB::CachedBazaarInputs')->delete_all;

    $c->res->redirect("/admin");
}

sub managenews : Chained('admin') Path('news') Args(0) {
    my ($self, $c) = @_;

    $c->stash->{newsItems} = [$c->model('DB::NewsItems')->search({}, {order_by => 'createtime DESC'})];

    $c->stash->{template} = 'news.tt';    
}

sub news_submit : Chained('admin') Path('news/submit') Args(0) {
    my ($self, $c) = @_;

    requirePost($c);
    
    my $contents = trim $c->request->params->{"contents"};
    my $createtime = time;
    
    $c->model('DB::NewsItems')->create({
        createtime => $createtime,
        contents => $contents,
        author => $c->user->username
    });

    $c->res->redirect("/admin/news");
}

sub news_delete : Chained('admin') Path('news/delete') Args(1) {
    my ($self, $c, $id) = @_;

    txn_do($c->model('DB')->schema, sub {
        my $newsItem = $c->model('DB::NewsItems')->find($id)
          or notFound($c, "Newsitem with id $id doesn't exist.");
        $newsItem->delete;
    });
        
    $c->res->redirect("/admin/news");
}

sub force_eval : Chained('admin') Path('eval') Args(2) {
    my ($self, $c, $projectName, $jobsetName) = @_;
    
    my $project = $c->model('DB::Projects')->find($projectName)
        or notFound($c, "Project $projectName doesn't exist.");

    $c->stash->{project} = $project;
    $c->stash->{jobset_} = $project->jobsets->search({name => $jobsetName});
    $c->stash->{jobset} = $c->stash->{jobset_}->single
        or notFound($c, "Jobset $jobsetName doesn't exist.");
    
    (my $res, my $stdout, my $stderr) = captureStdoutStderr(60, ("hydra_evaluator.pl", $projectName, $jobsetName));
            
    $c->res->redirect("/project/$projectName");
}

1;

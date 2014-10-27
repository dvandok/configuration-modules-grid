# ${license-info}
# ${developer-info}
# ${author-info}
# ${build-info}
#

package NCM::Component::mkgridmap;

use strict;
use NCM::Component;
use vars qw(@ISA $EC);
@ISA = qw(NCM::Component);
$EC=LC::Exception::Context->new->will_store_all;
use NCM::Check;
use Readonly;

use EDG::WP4::CCM::Element;

use File::Copy;
use LC::Check;
use CAF::Process;

local(*DTA);

Readonly my $BASE => "/software/components/mkgridmap";
Readonly my $VOBASE => "/system/vo";


##########################################################################
sub Configure($$@) {
##########################################################################
    
  my ($self, $config) = @_;

  # Load component config and VO config into hashes
  my $mkgridmap_config = $config->getElement($BASE)->getTree();
  my $vos_config = $config->getElement($VOBASE)->getTree();
  my $lcmaps_config = $mkgridmap_config->{lcmaps};
  
  # List of VOs to process: voList property if defined, else all VOs defined
  # under $VOBASE
  my @vo_list;
  if ( $mkgridmap_config->{voList} ) {
    for my $vo ( @{$mkgridmap_config->{voList}}) {
      if ( $vos_config->{$vo} ) {
        push @vo_list, $vo;
      } else {
        $self->error("VO $vo is not part of configuration ($VOBASE)");
      }
    }
  } else {
    @vo_list = sort(keys(%{$vos_config})); # if you need a different order, specify voList
  }
    
  # Save the date.
  my $date = localtime();

  # LCMAPS groupfile format
  my $lcmaps_flavor = 'glite';
  if ( $lcmaps_config->{flavor} ) {
    $lcmaps_flavor = $lcmaps_config->{flavor};
  }
  
  
  # Build LCMAPS gridmapfile and groupmapfile.
    
  for my $mapfile ('gridmapfile','groupmapfile') {
    if ( $lcmaps_config->{$mapfile} ) {
      my $contents;

      $self->info("Checking LCMAPS $mapfile (flavor=$lcmaps_flavor)...");

      $contents = << "EOF"
###########################################################################
#
# File generated by ncm-mkgridmap. DO NOT EDIT.
# 
# VOMS mappings to be imported into grid-mapfile.
# 
###########################################################################

EOF
;

      # Loop over all of the defined VOs to fill out this section. Looking at
      # the values: /system/vo/*/voms/*/(fqan|user|group). 
      for my $name (@vo_list) {
        my $voentry = $vos_config->{$name};
        
        if ( $voentry->{voms} ) {
          my $voname = $voentry->{name};
          $contents .= "# $voname\n";
    
          for my $voms_entry (@{$voentry->{voms}}) {
            my $fqan = $voms_entry->{fqan};
            if ( $lcmaps_flavor eq 'edg' ) {
              $fqan = '/VO=' . $voname . '/GROUP=' . $fqan;
              $fqan =~ s%/Role=%/ROLE=%;
              $fqan =~ s%/Capability=%/CAPABILITY=%;
            }
            my $mapping_type;
            if ( $mapfile eq 'gridmapfile') {
              $mapping_type = 'user';
            } else {
              $mapping_type = 'group';
            }
            if ( $voms_entry->{$mapping_type} ) {
              $contents .= "\"$fqan\" $voms_entry->{$mapping_type}\n";
            }
          }
          $contents .= "\n";
        }
      }
      
      # Update configuration file
      if ($self->write_conf_file($lcmaps_config->{$mapfile},$contents)) {
        $self->error("Error updating LCMAPS $mapfile ($lcmaps_config->{$mapfile})");
      }
    }
  }


  #
  # Now, produce the configuration file and generate all the map file requested.
  # 2 formats are available :
  #    - edg : each DN is associated with a pool account prefix
  #    - lcgdm : each DN is associated with a VO name. This format is used
  #              by LCC products (e.g. DPM and LFC) that provide VOMS
  #              integration for authorization to map non VOMS authenticated
  #              users.
  #

  for my $entry_name (sort(keys(%{$mkgridmap_config->{entries}}))) {
    $self->info("Checking $entry_name configuration...");

    my $entry = $mkgridmap_config->{entries}->{$entry_name};

    # Normaly 'format' is a required property, set default just in case
    my $fmt = "edg";
    if ( $entry->{format} ) {
      $fmt = $entry->{format};
    }

    if ( ($fmt eq "edg") || ($fmt eq "lcgdm") ) {
      $self->info("Generating configuration file for $entry_name (format: $fmt)");
    } else {
      $self->error("Mapfile $entry_name : unsupported format ($fmt)");
      next;
    }

    # Header of the file.
    my $contents = << "EOF"
##############################################################################
#
# File generated by ncm-mkgridmap
#
##############################################################################

EOF
;

    # Header for the VO sections.
    $contents .= << "EOF"

##############################################################################
# EDG Virtual Organisations
# eg 'group ldap://grid-vo.cnaf.infn.it/ou=testbed1,o=infn,c=it .infngrid'
##############################################################################

EOF
;

    # Loop over all of the defined VOs to fill out this section. Looking at
    # the values: /system/vo/*/auth/*/(uri|user). 
    for my $name (@vo_list) {
      my $voentry = $vos_config->{$name};
      
      if ( $voentry->{auth} ) {
        my $voname = $voentry->{name};
        $contents .= "# $voname\n";
    
        for my $auth_entry (@{$voentry->{auth}}) {
          my $uri = $auth_entry->{uri};
          my $user;
          if ( $fmt eq "edg" ) {
            $user = $auth_entry->{user};
          } else {
            $user = lc("$voname");
          }
          $contents .= "group $uri $user\n";
        }
        $contents .= "\n";
      }
    }

    # Header for the authorization groups section.
    $contents .= << "EOF"

#############################################################################
# List of auth URIs
# eg 'auth ldap://marianne.in2p3.fr/ou=People,o=testbed,dc=eu-datagrid,dc=org'
#
# If these are defined then users must be authorised in one of the following
# auth servers.
#############################################################################

EOF
;

    # Loop over all of the defined authorization URIs.  Looking at the
    # values: /software/components/mkgridmap/entries/*/authURIs.
    for my $uri ( @{$entry->{authURIs}} ) {
      $contents .= "auth $uri\n";
    }
    
    # Header for the authorization groups section.
    $contents .= << "EOF"

#############################################################################
# DEFAULT_LCLUSER: default_lcluser lcluser
# e.g. 'default_lcuser .'
#############################################################################

EOF
;

    # Default local user. Looking at the value:
    # /software/components/mkgridmap/lcuser.
    if ( $entry->{lcuser} ) {
      $contents .= "default_lcuser " . $entry->{lcuser} . "\n";
    }
    
    # Header for allow/deny patterns. 
    $contents .= << "EOF"

#############################################################################
# ALLOW and DENY: deny|allow pattern_to_match
# e.g. 'allow *INFN*'
#############################################################################

EOF
;

    # Default local user. Looking at the value:
    # /software/components/mkgridmap/lcuser.
    if ( $entry->{allow} ) {
      $contents .= "allow " . $entry->{allow} . "\n";
    }
    if ( $entry->{deny} ) {
      $contents .= "deny " . $entry->{deny} . "\n";
    }

    # Header for local gridmap file.
    $contents .= << "EOF"

#############################################################################
# Local grid-mapfile to import and overide all the above information.
# e.g. 'gmf_local /opt/edg/etc/grid-mapfile-local'
#############################################################################

EOF
;

    # Local gridmap file. Looking at the value:
    # /software/components/mkgridmap/gmflocal.
    # this could be either a string or list of strings
    if ( $entry->{gmflocal} ) {
      if (ref($entry->{gmflocal}) eq "ARRAY") {
         for my $gmf (@{$entry->{gmflocal}}) {
            $contents .= "gmf_local " . $gmf . "\n";
         }
      } else {
         $contents .= "gmf_local " . $entry->{gmflocal} . "\n";
      }
    }
      
    # The mapping for VOMS attributes managed by LCMAPS.
    if ( $lcmaps_config->{gridmapfile} ) {
      $contents .= "gmf_local " . $lcmaps_config->{gridmapfile} . "\n";
    }
      
    # Update configuration file
    if ($self->write_conf_file($entry->{mkgridmapconf},$contents)) {
      $self->error("Error updating configuration $entry->{mkgridmapconf}");
      next;
    }

    # Do the same for the local gridmap file if necessary. 
    if ( $entry->{gmflocal} && $entry->{overwrite} ) {
      my $contents = << "EOF"
###########################################################################
#
# File generated by ncm-mkgridmap
# 
# A list of user mappings that will be imported into the grid-mapfile.
# 
###########################################################################

EOF
;

      # Loop over all of the defined local entries.  Looking at the
      # values: /software/components/mkgridmap/entries/*/locals/(cert|user).
	    for my $local_entry (@{$entry->{locals}}) {
         $contents .= '"' . $local_entry->{cert} . '" ' . $local_entry->{user} . "\n";
	    }

      # Update configuration file
      if ($self->write_conf_file($entry->{gmflocal},$contents)) {
        $self->error("Error updating configuration file $entry->{gmflocal}");
        next;
      }
    }
    
    # Try regenerating the gridmap file. 
    if ( $entry->{command} ) {
      $self->info("Regenerating $entry_name gridmapfile");
      my @command = $self->tokenize_cmd($entry->{command});
      unless ( @command ) {
        $self->error("Error tokenizing command to generate gridmapfile (".$entry->{command}.")");
        next;
      }
      my $proc = CAF::Process->new(@command);
      my $output = $proc->output();
      if ( $? ) {
        $self->error("Regeneration of $entry_name gridmapfile failed ($output)");
      }
    }
  }



    return 1;
}


# Function to create/update configuration file

sub write_conf_file ($$$) {
  my ($self, $fname, $contents) = @_;

  # might get an array ref instead of filename - use first entry
  if(ref($fname) eq 'ARRAY') {
     $fname = $$fname[0];
  }
  # Now just create the new configuration file.  Be careful to save
  # a backup of the previous file if necessary. 
  my $result = LC::Check::file($fname,
                               backup => ".old",
                               contents => $contents,
                              );
  if ( $result >= 0 ) {
    $result = 0;
  }
  return $result;
}


# Function to tokenize a command string.
# Returns an array that can be passed to CAF::Process

sub tokenize_cmd {
  my ($self, $command) = @_;
  unless ( defined($command) ) {
    $self->error("Internal error: 'command' argument undefined in tokenize_cmd()");
    return;
  }

  my @cmd = split /\s+/, $command;
  return @cmd
}


1;      # Required for PERL modules

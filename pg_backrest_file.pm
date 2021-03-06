####################################################################################################################################
# FILE MODULE
####################################################################################################################################
package pg_backrest_file;

use threads;

use Moose;
use strict;
use warnings;
use Carp;
use Net::OpenSSH;
use IPC::Open3;
use File::Basename;
use IPC::System::Simple qw(capture);

use lib dirname($0);
use pg_backrest_utility;

use Exporter qw(import);
our @EXPORT = qw(PATH_DB PATH_DB_ABSOLUTE PATH_BACKUP PATH_BACKUP_ABSOLUTE PATH_BACKUP_CLUSTER PATH_BACKUP_TMP PATH_BACKUP_ARCHIVE);

# Extension and permissions
has strCompressExtension => (is => 'ro', default => 'gz');
has strDefaultPathPermission => (is => 'bare', default => '0750');
has strDefaultFilePermission => (is => 'ro', default => '0640');

# Command strings
has strCommandChecksum => (is => 'bare');
has strCommandCompress => (is => 'bare');
has strCommandDecompress => (is => 'bare');
has strCommandCat => (is => 'bare', default => 'cat %file%');
has strCommandManifest => (is => 'bare');

# Lock path
has strLockPath => (is => 'bare');

# Files to hold stderr
#has strBackupStdErrFile => (is => 'bare');
#has strDbStdErrFile => (is => 'bare');

# Module variables
has strDbUser => (is => 'bare');                # Database user
has strDbHost => (is => 'bare');                # Database host
has oDbSSH => (is => 'bare');                   # Database SSH object

has strBackupUser => (is => 'bare');            # Backup user
has strBackupHost => (is => 'bare');            # Backup host
has oBackupSSH => (is => 'bare');               # Backup SSH object
has strBackupPath => (is => 'bare');            # Backup base path
has strBackupClusterPath => (is => 'bare');     # Backup cluster path

# Process flags
has bNoCompression => (is => 'bare');
has strStanza => (is => 'bare');
has iThreadIdx => (is => 'bare');

####################################################################################################################################
# PATH_GET Constants
####################################################################################################################################
use constant
{
    PATH_DB              => 'db',
    PATH_DB_ABSOLUTE     => 'db:absolute',
    PATH_BACKUP          => 'backup',
    PATH_BACKUP_ABSOLUTE => 'backup:absolute',
    PATH_BACKUP_CLUSTER  => 'backup:cluster',
    PATH_BACKUP_TMP      => 'backup:tmp',
    PATH_BACKUP_ARCHIVE  => 'backup:archive',
    PATH_LOCK_ERR        => 'lock:err'
};

####################################################################################################################################
# CONSTRUCTOR
####################################################################################################################################
sub BUILD
{
    my $self = shift;
    
    # Make sure the backup path is defined
    if (!defined($self->{strBackupPath}))
    {
        confess &log(ERROR, "common:backup_path undefined");
    }

    # Create the backup cluster path
    $self->{strBackupClusterPath} = $self->{strBackupPath} . "/" . $self->{strStanza};

    # Create the ssh options string
    if (defined($self->{strBackupHost}) || defined($self->{strDbHost}))
    {
        my $strOptionSSHRequestTTY = "RequestTTY=yes";
        my $strOptionSSHCompression = "Compression=no";

        if ($self->{bNoCompression})
        {
            $strOptionSSHCompression = "Compression=yes";
        }

        # Connect SSH object if backup host is defined
        if (!defined($self->{oBackupSSH}) && defined($self->{strBackupHost}))
        {
            &log(TRACE, "connecting to backup ssh host " . $self->{strBackupHost});
            
            $self->{oBackupSSH} = Net::OpenSSH->new($self->{strBackupHost}, timeout => 300, user => $self->{strBackupUser},
                                      default_stderr_file => $self->path_get(PATH_LOCK_ERR, "file"),
                                      master_opts => [-o => $strOptionSSHCompression, -o => $strOptionSSHRequestTTY]);
            $self->{oBackupSSH}->error and confess &log(ERROR, "unable to connect to $self->{strBackupHost}: " . $self->{oBackupSSH}->error);
        }

        # Connect SSH object if db host is defined
        if (!defined($self->{oDbSSH}) && defined($self->{strDbHost}))
        {
            &log(TRACE, "connecting to database ssh host $self->{strDbHost}");

            $self->{oDbSSH} = Net::OpenSSH->new($self->{strDbHost}, timeout => 300, user => $self->{strDbUser},
                                  default_stderr_file => $self->path_get(PATH_LOCK_ERR, "file"),
                                  master_opts => [-o => $strOptionSSHCompression, -o => $strOptionSSHRequestTTY]);
            $self->{oDbSSH}->error and confess &log(ERROR, "unable to connect to $self->{strDbHost}: " . $self->{oDbSSH}->error);
        }
    }
}

####################################################################################################################################
# CLONE
####################################################################################################################################
sub clone
{
    my $self = shift;
    my $iThreadIdx = shift;

    return pg_backrest_file->new
    (
        strCompressExtension => $self->{strCompressExtension},
        strDefaultPathPermission => $self->{strDefaultPathPermission},
        strDefaultFilePermission => $self->{strDefaultFilePermission},
        strCommandChecksum => $self->{strCommandChecksum},
        strCommandCompress => $self->{strCommandCompress},
        strCommandDecompress => $self->{strCommandDecompress},
        strCommandCat => $self->{strCommandCat},
        strCommandManifest => $self->{strCommandManifest},
#        oDbSSH => $self->{strDbSSH},
        strDbUser => $self->{strDbUser},
        strDbHost => $self->{strDbHost},
#        oBackupSSH => $self->{strBackupSSH},
        strBackupUser => $self->{strBackupUser},
        strBackupHost => $self->{strBackupHost},
        strBackupPath => $self->{strBackupPath},
        strBackupClusterPath => $self->{strBackupClusterPath},
        bNoCompression => $self->{bNoCompression},
        strStanza => $self->{strStanza},
        iThreadIdx => $iThreadIdx,
        strLockPath => $self->{strLockPath}
    );
}

####################################################################################################################################
# ERROR_GET
####################################################################################################################################
sub error_get
{
    my $self = shift;
    
    my $strErrorFile = $self->path_get(PATH_LOCK_ERR, "file");
    
    open my $hFile, '<', $strErrorFile or return "error opening ${strErrorFile} to read STDERR output";
    
    my $strError = do {local $/; <$hFile>};
    close $hFile;
    
    return trim($strError);
}

####################################################################################################################################
# PATH_GET
####################################################################################################################################
sub path_type_get
{
    my $self = shift;
    my $strType = shift;

    # If db type
    if ($strType =~ /^db(\:.*){0,1}/)
    {
        return PATH_DB;
    }
    # Else if backup type
    elsif ($strType =~ /^backup(\:.*){0,1}/)
    {
        return PATH_BACKUP;
    }

    # Error when path type not recognized
    confess &log(ASSERT, "no known path types in '${strType}'");
}

sub path_get
{
    my $self = shift;
    my $strType = shift;    # Base type of the path to get (PATH_DB_ABSOLUTE, PATH_BACKUP_TMP, etc)
    my $strFile = shift;    # File to append to the base path (can include a path as well)
    my $bTemp = shift;      # Return the temp file for this path type - only some types have temp files

    # Only allow temp files for PATH_BACKUP_ARCHIVE and PATH_BACKUP_TMP
    if (defined($bTemp) && $bTemp && !($strType eq PATH_BACKUP_ARCHIVE || $strType eq PATH_BACKUP_TMP || $strType eq PATH_DB_ABSOLUTE))
    {
        confess &log(ASSERT, "temp file not supported on path " . $strType);
    }

    # Get absolute db path
    if ($strType eq PATH_DB_ABSOLUTE)
    {
        if (defined($bTemp) && $bTemp)
        {
            return $strFile . ".backrest.tmp";
        }

        return $strFile;
    }

    # Make sure the base backup path is defined
    if (!defined($self->{strBackupPath}))
    {
        confess &log(ASSERT, "\$strBackupPath not yet defined");
    }

    # Get absolute backup path
    if ($strType eq PATH_BACKUP_ABSOLUTE)
    {
        # Need a check in here to make sure this is relative to the backup path

        return $strFile;
    }

    # Get base backup path
    if ($strType eq PATH_BACKUP)
    {
        return $self->{strBackupPath} . (defined($strFile) ? "/${strFile}" : "");
    }

    # Make sure the cluster is defined
    if (!defined($self->{strStanza}))
    {
        confess &log(ASSERT, "\$strStanza not yet defined");
    }

    # Get the lock error path
    if ($strType eq PATH_LOCK_ERR)
    {
        my $strTempPath = "$self->{strLockPath}";

        return ${strTempPath} . (defined($strFile) ? "/${strFile}" .
                                (defined($self->{iThreadIdx}) ? ".$self->{iThreadIdx}" : "") . ".err" : "");
    }

    # Get the backup tmp path
    if ($strType eq PATH_BACKUP_TMP)
    {
        my $strTempPath = "$self->{strBackupPath}/temp/$self->{strStanza}.tmp";

        if (defined($bTemp) && $bTemp)
        {
            return "${strTempPath}/file.tmp" . (defined($self->{iThreadIdx}) ? ".$self->{iThreadIdx}" : "");
        }

        return "${strTempPath}" . (defined($strFile) ? "/${strFile}" : "");
    }

    # Get the backup archive path
    if ($strType eq PATH_BACKUP_ARCHIVE)
    {
        my $strArchivePath = "$self->{strBackupPath}/archive/$self->{strStanza}";
        my $strArchive;

        if (defined($bTemp) && $bTemp)
        {
            return "${strArchivePath}/file.tmp" . (defined($self->{iThreadIdx}) ? ".$self->{iThreadIdx}" : "");
        }

        if (defined($strFile))
        {
            $strArchive = substr(basename($strFile), 0, 24);

            if ($strArchive !~ /^([0-F]){24}$/)
            {
                return "${strArchivePath}/${strFile}";
            }
        }

        return $strArchivePath . (defined($strArchive) ? "/" . substr($strArchive, 0, 16) : "") .
               (defined($strFile) ? "/" . $strFile : "");
    }

    if ($strType eq PATH_BACKUP_CLUSTER)
    {
        return $self->{strBackupPath} . "/backup/$self->{strStanza}" . (defined($strFile) ? "/${strFile}" : "");
    }

    # Error when path type not recognized
    confess &log(ASSERT, "no known path types in '${strType}'");
}

####################################################################################################################################
# LINK_CREATE
####################################################################################################################################
sub link_create
{
    my $self = shift;
    my $strSourcePathType = shift;
    my $strSourceFile = shift;
    my $strDestinationPathType = shift;
    my $strDestinationFile = shift;
    my $bHard = shift;
    my $bRelative = shift;
    my $bPathCreate = shift;

    # if bHard is not defined default to false
    $bHard = defined($bHard) ? $bHard : false;

    # if bRelative is not defined or bHard is true, default to false
    $bRelative = !defined($bRelative) || $bHard ? false : $bRelative;

    # if bPathCreate is not defined, default to true
    $bPathCreate = defined($bPathCreate) ? $bPathCreate : true;
    
    # Source and destination path types must be the same (both PATH_DB or both PATH_BACKUP)
    if ($self->path_type_get($strSourcePathType) ne $self->path_type_get($strDestinationPathType))
    {
        confess &log(ASSERT, "path types must be equal in link create");
    }

    # Generate source and destination files
    my $strSource = $self->path_get($strSourcePathType, $strSourceFile);
    my $strDestination = $self->path_get($strDestinationPathType, $strDestinationFile);

    # If the destination path is backup and does not exist, create it
    if ($bPathCreate && $self->path_type_get($strDestinationPathType) eq PATH_BACKUP)
    {
        $self->path_create(PATH_BACKUP_ABSOLUTE, dirname($strDestination));
    }

    unless (-e $strSource)
    {
        if (-e $strSource . ".$self->{strCompressExtension}")
        {
            $strSource .= ".$self->{strCompressExtension}";
            $strDestination .= ".$self->{strCompressExtension}";
        }
        else
        {
            # Error when a hardlink will be created on a missing file
            if ($bHard)
            {
                confess &log(ASSERT, "unable to find ${strSource}(.$self->{strCompressExtension}) for link");
            }
        }
    }

    # Generate relative path if requested
    if ($bRelative)
    {
        my $iCommonLen = common_prefix($strSource, $strDestination);

        if ($iCommonLen != 0)
        {
            $strSource = ("../" x substr($strDestination, $iCommonLen) =~ tr/\///) . substr($strSource, $iCommonLen);
        }
    }

    # Create the command
    my $strCommand = "ln" . (!$bHard ? " -s" : "") . " ${strSource} ${strDestination}";

    # Run remotely
    if ($self->is_remote($strSourcePathType))
    {
        &log(TRACE, "link_create: remote ${strSourcePathType} '${strCommand}'");

        my $oSSH = $self->remote_get($strSourcePathType);
        $oSSH->system($strCommand) or confess &log("unable to create link from ${strSource} to ${strDestination}");
    }
    # Run locally
    else
    {
        &log(TRACE, "link_create: local '${strCommand}'");
        system($strCommand) == 0 or confess &log("unable to create link from ${strSource} to ${strDestination}");
    }
}

####################################################################################################################################
# PATH_CREATE
#
# Creates a path locally or remotely.  Currently does not error if the path already exists.  Also does not set permissions if the
# path aleady exists.
####################################################################################################################################
sub path_create
{
    my $self = shift;
    my $strPathType = shift;
    my $strPath = shift;
    my $strPermission = shift;

    # If no permissions are given then use the default
    if (!defined($strPermission))
    {
        $strPermission = $self->{strDefaultPathPermission};
    }

    # Get the path to create
    my $strPathCreate = $strPath;
    
    if (defined($strPathType))
    {
        $strPathCreate = $self->path_get($strPathType, $strPath);
    }

    my $strCommand = "mkdir -p -m ${strPermission} ${strPathCreate}";

    # Run remotely
    if ($self->is_remote($strPathType))
    {
        &log(TRACE, "path_create: remote ${strPathType} '${strCommand}'");

        my $oSSH = $self->remote_get($strPathType);
        $oSSH->system($strCommand) or confess &log("unable to create remote path ${strPathType}:${strPath}");
    }
    # Run locally
    else
    {
        &log(TRACE, "path_create: local '${strCommand}'");
        system($strCommand) == 0 or confess &log(ERROR, "unable to create path ${strPath}");
    }
}

####################################################################################################################################
# IS_REMOTE
#
# Determine whether any operations are being performed remotely.  If $strPathType is defined, the function will return true if that
# path is remote.  If $strPathType is not defined, then function will return true if any path is remote.
####################################################################################################################################
sub is_remote
{
    my $self = shift;
    my $strPathType = shift;

    # If the SSH object is defined then some paths are remote
    if (defined($self->{oDbSSH}) || defined($self->{oBackupSSH}))
    {
        # If path type is not defined but the SSH object is, then some paths are remote
        if (!defined($strPathType))
        {
            return true;
        }

        # If a host is defined for the path then it is remote
        if (defined($self->{strBackupHost}) && $self->path_type_get($strPathType) eq PATH_BACKUP ||
            defined($self->{strDbHost}) && $self->path_type_get($strPathType) eq PATH_DB)
        {
            return true;
        }
    }

    return false;
}

####################################################################################################################################
# REMOTE_GET
#
# Get remote SSH object depending on the path type.
####################################################################################################################################
sub remote_get
{
    my $self = shift;
    my $strPathType = shift;
    
    # Get the db SSH object
    if ($self->path_type_get($strPathType) eq PATH_DB && defined($self->{oDbSSH}))
    {
        return $self->{oDbSSH};
    }

    # Get the backup SSH object
    if ($self->path_type_get($strPathType) eq PATH_BACKUP && defined($self->{oBackupSSH}))
    {
        return $self->{oBackupSSH}
    }

    # Error when no ssh object is found
    confess &log(ASSERT, "path type ${strPathType} does not have a defined ssh object");
}

####################################################################################################################################
# FILE_MOVE
#
# Moves a file locally or remotely.
####################################################################################################################################
sub file_move
{
    my $self = shift;
    my $strSourcePathType = shift;
    my $strSourceFile = shift;
    my $strDestinationPathType = shift;
    my $strDestinationFile = shift;
    my $bPathCreate = shift;

    # if bPathCreate is not defined, default to true
    $bPathCreate = defined($bPathCreate) ? $bPathCreate : true;

    &log(TRACE, "file_move: ${strSourcePathType}: " . (defined($strSourceFile) ? ":${strSourceFile}" : "") .
                " to ${strDestinationPathType}" . (defined($strDestinationFile) ? ":${strDestinationFile}" : ""));

    # Get source and desination files
    if ($self->path_type_get($strSourcePathType) ne $self->path_type_get($strSourcePathType))
    {
        confess &log(ASSERT, "source and destination path types must be equal");
    }

    my $strSource = $self->path_get($strSourcePathType, $strSourceFile);
    my $strDestination = $self->path_get($strDestinationPathType, $strDestinationFile);

    # If the destination path is backup and does not exist, create it
    if ($bPathCreate && $self->path_type_get($strDestinationPathType) eq PATH_BACKUP)
    {
        $self->path_create(PATH_BACKUP_ABSOLUTE, dirname($strDestination));
    }

    my $strCommand = "mv ${strSource} ${strDestination}";

    # Run remotely
    if ($self->is_remote($strDestinationPathType))
    {
        &log(TRACE, "file_move: remote ${strDestinationPathType} '${strCommand}'");

        my $oSSH = $self->remote_get($strDestinationPathType);
        $oSSH->system($strCommand)
            or confess &log("unable to move remote ${strDestinationPathType}:${strSourceFile} to ${strDestinationFile}");
    }
    # Run locally
    else
    {
        &log(TRACE, "file_move: '${strCommand}'");

        system($strCommand) == 0 or confess &log("unable to move local ${strSourceFile} to ${strDestinationFile}");
    }
}

####################################################################################################################################
# FILE_COPY
####################################################################################################################################
sub file_copy
{
    my $self = shift;
    my $strSourcePathType = shift;
    my $strSourceFile = shift;
    my $strDestinationPathType = shift;
    my $strDestinationFile = shift;
    my $bNoCompressionOverride = shift;
    my $lModificationTime = shift;
    my $strPermission = shift;
    my $bPathCreate = shift;
    my $bConfessCopyError = shift;

    # if bPathCreate is not defined, default to true
    $bPathCreate = defined($bPathCreate) ? $bPathCreate : true;
    $bConfessCopyError = defined($bConfessCopyError) ? $bConfessCopyError : true;

    &log(TRACE, "file_copy: ${strSourcePathType}: " . (defined($strSourceFile) ? ":${strSourceFile}" : "") .
                " to ${strDestinationPathType}" . (defined($strDestinationFile) ? ":${strDestinationFile}" : ""));

    # Modification time and permissions cannot be set remotely
    if ((defined($lModificationTime) || defined($strPermission)) && $self->is_remote($strDestinationPathType))
    {
        confess &log(ASSERT, "modification time and permissions cannot be set on remote destination file");
    }

    # Generate source, destination and tmp filenames
    my $strSource = $self->path_get($strSourcePathType, $strSourceFile);
    my $strDestination = $self->path_get($strDestinationPathType, $strDestinationFile);
    my $strDestinationTmp = $self->path_get($strDestinationPathType, $strDestinationFile, true);

    # Is this already a compressed file?
    my $bAlreadyCompressed = $strSource =~ "^.*\.$self->{strCompressExtension}\$";

    if ($bAlreadyCompressed && $strDestination !~ "^.*\.$self->{strCompressExtension}\$")
    {
        $strDestination .= ".$self->{strCompressExtension}";
    }

    # Does the file need compression?
    my $bCompress = !((defined($bNoCompressionOverride) && $bNoCompressionOverride) ||
                      (!defined($bNoCompressionOverride) && $self->{bNoCompression}));

    # If the destination path is backup and does not exist, create it
    if ($bPathCreate && $self->path_type_get($strDestinationPathType) eq PATH_BACKUP)
    {
        $self->path_create(PATH_BACKUP_ABSOLUTE, dirname($strDestination));
    }

    # Generate the command string depending on compression/decompression/cat
    my $strCommand = $self->{strCommandCat};
    
    if (!$bAlreadyCompressed && $bCompress)
    {
        $strCommand = $self->{strCommandCompress};
        $strDestination .= ".gz";
    }
    elsif ($bAlreadyCompressed && !$bCompress)
    {
        $strCommand = $self->{strCommandDecompress};
        $strDestination = substr($strDestination, 0, length($strDestination) - length($self->{strCompressExtension}) - 1);
    }

    $strCommand =~ s/\%file\%/${strSource}/g;
    $strCommand .= " 2> /dev/null";

    # If this command is remote on only one side
    if ($self->is_remote($strSourcePathType) && !$self->is_remote($strDestinationPathType) ||
        !$self->is_remote($strSourcePathType) && $self->is_remote($strDestinationPathType))
    {
        # Else if the source is remote
        if ($self->is_remote($strSourcePathType))
        {
            &log(TRACE, "file_copy: remote ${strSource} to local ${strDestination}");

            # Open the destination file for writing (will be streamed from the ssh session)
            my $hFile;
            open($hFile, ">", $strDestinationTmp) or confess &log(ERROR, "cannot open ${strDestination}");

            # Execute the command through ssh
            my $oSSH = $self->remote_get($strSourcePathType);
            
            unless ($oSSH->system({stdout_fh => $hFile}, $strCommand))
            {
                close($hFile) or confess &log(ERROR, "cannot close file ${strDestinationTmp}");
                
                my $strResult = "unable to execute ssh '${strCommand}'";
                $bConfessCopyError ? confess &log(ERROR, $strResult) : return false;
            }

            # Close the destination file handle
            close($hFile) or confess &log(ERROR, "cannot close file ${strDestinationTmp}");
        }
        # Else if the destination is remote
        elsif ($self->is_remote($strDestinationPathType))
        {
            &log(TRACE, "file_copy: local ${strSource} ($strCommand) to remote ${strDestination}");

            # Open the input command as a stream
            my $hOut;
            my $pId = open3(undef, $hOut, undef, $strCommand) or confess(ERROR, "unable to execute '${strCommand}'");

            # Execute the command though ssh
            my $oSSH = $self->remote_get($strDestinationPathType);
            $oSSH->system({stdin_fh => $hOut}, "cat > ${strDestinationTmp}") or confess &log(ERROR, "unable to execute ssh 'cat'");

            # Wait for the stream process to finish
            waitpid($pId, 0);
            my $iExitStatus = ${^CHILD_ERROR_NATIVE} >> 8;
            
            if ($iExitStatus != 0)
            {
                my $strResult = "command '${strCommand}' returned " . $iExitStatus;
                $bConfessCopyError ? confess &log(ERROR, $strResult) : return false;
            }
        }
    }
    # If the source and destination are both remote but not the same remote
    elsif ($self->is_remote($strSourcePathType) && $self->is_remote($strDestinationPathType) &&
           $self->path_type_get($strSourcePathType) ne $self->path_type_get($strDestinationPathType))
    {
        &log(TRACE, "file_copy: remote ${strSource} to remote ${strDestination}");
        confess &log(ASSERT, "remote source and destination not supported");
    }
    # Else this is a local command or remote where both sides are the same remote
    else
    {
        # Complete the command by redirecting to the destination tmp file
        $strCommand .= " > ${strDestinationTmp}";

        if ($self->is_remote($strSourcePathType))
        {
            &log(TRACE, "file_copy: remote ${strSourcePathType} '${strCommand}'");

            my $oSSH = $self->remote_get($strSourcePathType);

            unless($oSSH->system($strCommand))
            {
                my $strResult = "unable to execute remote command ${strCommand}:" . oSSH->error;
                $bConfessCopyError ? confess &log(ERROR, $strResult) : return false;
            }
        }
        else
        {
            &log(TRACE, "file_copy: local '${strCommand}'");
            
            unless(system($strCommand) == 0)
            {
                my $strResult = "unable to copy local ${strSource} to local ${strDestinationTmp}";
                $bConfessCopyError ? confess &log(ERROR, $strResult) : return false;
            }
        }
    }

    # Set the file permission if required (this only works locally for now)
    if (defined($strPermission))
    {
        &log(TRACE, "file_copy: chmod ${strPermission}");

        system("chmod ${strPermission} ${strDestinationTmp}") == 0
            or confess &log(ERROR, "unable to set permissions for local ${strDestinationTmp}");
    }

    # Set the file modification time if required (this only works locally for now)
    if (defined($lModificationTime))
    {
        &log(TRACE, "file_copy: time ${lModificationTime}");

        utime($lModificationTime, $lModificationTime, $strDestinationTmp)
            or confess &log(ERROR, "unable to set time for local ${strDestinationTmp}");
    }

    # Move the file from tmp to final destination
    $self->file_move($self->path_type_get($strSourcePathType) . ":absolute", $strDestinationTmp,
                     $self->path_type_get($strDestinationPathType) . ":absolute",  $strDestination, $bPathCreate);
                     
    return true;
}

####################################################################################################################################
# FILE_HASH_GET
####################################################################################################################################
sub file_hash_get
{
    my $self = shift;
    my $strPathType = shift;
    my $strFile = shift;

    # For now this operation is not supported remotely.  Not currently needed.
    if ($self->is_remote($strPathType))
    {
        confess &log(ASSERT, "remote operation not supported");
    }

    if (!defined($self->{strCommandChecksum}))
    {
        confess &log(ASSERT, "\$strCommandChecksum not defined");
    }

    my $strPath = $self->path_get($strPathType, $strFile);
    my $strCommand;

    if (-e $strPath)
    {
        $strCommand = $self->{strCommandChecksum};
        $strCommand =~ s/\%file\%/${strPath}/g;
    }
    elsif (-e $strPath . ".$self->{strCompressExtension}")
    {
        $strCommand = $self->{strCommandDecompress};
        $strCommand =~ s/\%file\%/${strPath}/g;
        $strCommand .= " | " . $self->{strCommandChecksum};
        $strCommand =~ s/\%file\%//g;
    }
    else
    {
        confess &log(ASSERT, "unable to find $strPath(.$self->{strCompressExtension}) for checksum");
    }

    return trim(capture($strCommand)) or confess &log(ERROR, "unable to checksum ${strPath}");
}
####################################################################################################################################
# FILE_COMPRESS
####################################################################################################################################
sub file_compress
{
    my $self = shift;
    my $strPathType = shift;
    my $strFile = shift;

    # For now this operation is not supported remotely.  Not currently needed.
    if ($self->is_remote($strPathType))
    {
        confess &log(ASSERT, "remote operation not supported");
    }

    if (!defined($self->{strCommandCompress}))
    {
        confess &log(ASSERT, "\$strCommandCompress not defined");
    }

    my $strPath = $self->path_get($strPathType, $strFile);

    # Build the command
    my $strCommand = $self->{strCommandCompress};
    $strCommand =~ s/\%file\%/${strPath}/g;
    $strCommand =~ s/\ \-\-stdout//g;

    system($strCommand) == 0 or confess &log(ERROR, "unable to compress ${strPath}: ${strCommand}");
}

####################################################################################################################################
# FILE_LIST_GET
####################################################################################################################################
sub file_list_get
{
    my $self = shift;
    my $strPathType = shift;
    my $strPath = shift;
    my $strExpression = shift;
    my $strSortOrder = shift;

    # Get the root path for the file list
    my $strPathList = $self->path_get($strPathType, $strPath);

    # Builds the file list command
#    my $strCommand = "ls ${strPathList} | egrep \"$strExpression\"";
    my $strCommand = "ls -1 ${strPathList}";
    
    # Run the file list command
    my $strFileList = "";

    # Run remotely
    if ($self->is_remote($strPathType))
    {
        &log(TRACE, "file_list_get: remote ${strPathType}:${strPathList} ${strCommand}");

        my $oSSH = $self->remote_get($strPathType);
        $strFileList = $oSSH->capture($strCommand);
        
        if ($oSSH->error)
        {
            confess &log(ERROR, "unable to execute file list (${strCommand}): " . $self->error_get());
        }
    }
    # Run locally
    else
    {
        &log(TRACE, "file_list_get: local ${strPathType}:${strPathList} ${strCommand}");
        $strFileList = capture($strCommand);
    }

    # Split the files into an array
    my @stryFileList;
    
    if (defined($strExpression))
    {
        @stryFileList = grep(/$strExpression/i, split(/\n/, $strFileList));
    }
    else
    {
        @stryFileList = split(/\n/, $strFileList);
    }

    # Return the array in reverse order if specified
    if (defined($strSortOrder) && $strSortOrder eq "reverse")
    {
        return sort {$b cmp $a} @stryFileList;
    }
    
    # Return in normal sorted order
    return sort @stryFileList;
}

####################################################################################################################################
# FILE_EXISTS
####################################################################################################################################
sub file_exists
{
    my $self = shift;
    my $strPathType = shift;
    my $strPath = shift;

    # Get the root path for the manifest
    my $strPathExists = $self->path_get($strPathType, $strPath);

    # Builds the exists command
    my $strCommand = "ls ${strPathExists}";
    
    # Run the file exists command
    my $strExists = "";

    # Run remotely
    if ($self->is_remote($strPathType))
    {
        &log(TRACE, "file_exists: remote ${strPathType}:${strPathExists}");

        my $oSSH = $self->remote_get($strPathType);
        $strExists = trim($oSSH->capture($strCommand));
        
        if ($oSSH->error)
        {
            confess &log(ERROR, "unable to execute file exists (${strCommand}): " . $self->error_get());
        }
    }
    # Run locally
    else
    {
        &log(TRACE, "file_exists: local ${strPathType}:${strPathExists}");
        $strExists = trim(capture($strCommand));
    }

    &log(TRACE, "file_exists: search = ${strPathExists}, result = ${strExists}");

    # If the return from ls eq strPathExists then true
    return ($strExists eq $strPathExists);
}

####################################################################################################################################
# FILE_REMOVE
####################################################################################################################################
sub file_remove
{
    my $self = shift;
    my $strPathType = shift;
    my $strPath = shift;
    my $bTemp = shift;
    my $bErrorIfNotExists = shift;
    
    if (!defined($bErrorIfNotExists))
    {
        $bErrorIfNotExists = false;
    }

    # Get the root path for the manifest
    my $strPathRemove = $self->path_get($strPathType, $strPath, $bTemp);

    # Builds the exists command
    my $strCommand = "rm -f ${strPathRemove}";

    # Run remotely
    if ($self->is_remote($strPathType))
    {
        &log(TRACE, "file_remove: remote ${strPathType}:${strPathRemove}");

        my $oSSH = $self->remote_get($strPathType);
        $oSSH->system($strCommand) or $bErrorIfNotExists ? confess &log(ERROR, "unable to remove remote ${strPathType}:${strPathRemove}") : true;
        
        if ($oSSH->error)
        {
            confess &log(ERROR, "unable to execute file_remove (${strCommand}): " . $self->error_get());
        }
    }
    # Run locally
    else
    {
        &log(TRACE, "file_remove: local ${strPathType}:${strPathRemove}");
        system($strCommand) == 0 or $bErrorIfNotExists ? confess &log(ERROR, "unable to remove local ${strPathType}:${strPathRemove}") : true;
    }
}

####################################################################################################################################
# MANIFEST_GET
#
# Builds a path/file manifest starting with the base path and including all subpaths.  The manifest contains all the information
# needed to perform a backup or a delta with a previous backup.
####################################################################################################################################
sub manifest_get
{
    my $self = shift;
    my $strPathType = shift;
    my $strPath = shift;

    &log(TRACE, "manifest: " . $self->{strCommandManifest});

    # Get the root path for the manifest
    my $strPathManifest = $self->path_get($strPathType, $strPath);

    # Builds the manifest command
    my $strCommand = $self->{strCommandManifest};
    $strCommand =~ s/\%path\%/${strPathManifest}/g;
    
    # Run the manifest command
    my $strManifest;

    # Run remotely
    if ($self->is_remote($strPathType))
    {
        &log(TRACE, "manifest_get: remote ${strPathType}:${strPathManifest}");

        my $oSSH = $self->remote_get($strPathType);
        $strManifest = $oSSH->capture($strCommand) or
            confess &log(ERROR, "unable to execute remote manifest (${strCommand}): " . $self->error_get());
    }
    # Run locally
    else
    {
        &log(TRACE, "manifest_get: local ${strPathType}:${strPathManifest}");
        $strManifest = capture($strCommand) or confess &log(ERROR, "unable to execute local command '${strCommand}'");
    }

    # Load the manifest into a hash
    return data_hash_build("name\ttype\tuser\tgroup\tpermission\tmodification_time\tinode\tsize\tlink_destination\n" .
                           $strManifest, "\t", ".");
}

no Moose;
  __PACKAGE__->meta->make_immutable;
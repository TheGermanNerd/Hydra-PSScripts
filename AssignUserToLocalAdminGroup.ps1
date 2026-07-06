# This script adds the assigned user (VDI only) to the local admin group
LogWriter("Add assigned user to local admin group")
if ($global:Hydra_SessionHost_AssignedUser -eq "") {
    OutputWriter("There is currently no user assignment for this session host")
} else {
    # Try to get the localized name of the local administrator group
    $groupName=(New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-544")).Translate( [System.Security.Principal.NTAccount]).Value.Split("\")[1]
    try {
        Add-LocalGroupMember -Group $groupName -Member "$($global:Hydra_SessionHost_AssignedUser)"
        OutputWriter("User $($global:Hydra_SessionHost_AssignedUser) are added to local admin group")
    } catch [Microsoft.PowerShell.Commands.MemberExistsException] {
        OutputWriter "User $($global:Hydra_SessionHost_AssignedUser) are already in group"
    }
}
 

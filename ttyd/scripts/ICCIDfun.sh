edit_iccid_file() {
    local iccid_file="/path/to/iccid_master_file" # Path to the ICCID-APN-IPType master file

    echo "Enter ICCID to add or edit:"
    read iccid
    echo "Enter APN for $iccid:"
    read apn
    echo "Enter IP Type (IPV4, IPV6, IPV4V6) for $iccid [Default: IPV4V6]:"
    read iptype
    iptype=${iptype:-"IPV4V6"} # Default to IPV4V6 if not specified

    # Check if ICCID already exists
    if grep -q "$iccid" "$iccid_file"; then
        # Update existing ICCID's APN and IP Type
        sed -i "/$iccid/c\\$iccid,$apn,$iptype" "$iccid_file"
    else
        # Add new ICCID, APN, and IP Type
        echo "$iccid,$apn,$iptype" >> "$iccid_file"
    fi
    echo "ICCID file updated."
}

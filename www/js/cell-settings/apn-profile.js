document.addEventListener('DOMContentLoaded', function() {
    const form = document.getElementById('apnProfileForm');

    // Helper function to show notifications
    function showNotification(message, isError = false) {
        // Remove existing notification if any
        const existingNotification = form.previousElementSibling;
        if (existingNotification && existingNotification.classList.contains('notification')) {
            existingNotification.remove();
        }

        const notification = document.createElement('div');
        notification.className = `notification ${isError ? 'is-danger' : 'is-success'} is-light`;
        notification.innerHTML = `
            <button class="delete"></button>
            ${message}
        `;
        
        form.insertAdjacentElement('beforebegin', notification);
        
        // Remove notification after 5 seconds
        setTimeout(() => notification.remove(), 5000);
        
        // Allow manual close
        notification.querySelector('.delete').addEventListener('click', () => notification.remove());
    }

    // Function to validate ICCID format
    function validateICCID(iccid) {
        return /^\d{19,20}$/.test(iccid);
    }

    // Function to validate APN format
    function validateAPN(apn) {
        return /^[a-zA-Z0-9.-]+$/.test(apn);
    }

    // Function to set select element value
    function setSelectValue(selectElement, value) {
        const options = selectElement.options;
        for (let i = 0; i < options.length; i++) {
            if (options[i].value === value) {
                selectElement.selectedIndex = i;
                break;
            }
        }
    }

    // Function to fetch and display existing profiles
    function fetchProfiles() {
        fetch('/cgi-bin/fetch-apn-profiles.sh')
            .then(response => response.json())
            .then(data => {
                if (data.status === 'success') {
                    // Fill Profile 1
                    if (data.profiles.profile1) {
                        const p1 = data.profiles.profile1;
                        if (p1.iccid) document.getElementById('iccidProfile1').value = p1.iccid;
                        if (p1.apn) document.getElementById('apnProfile1').value = p1.apn;
                        if (p1.pdpType) setSelectValue(document.getElementById('apnPDPType1'), p1.pdpType);
                    }

                    // Fill Profile 2
                    if (data.profiles.profile2) {
                        const p2 = data.profiles.profile2;
                        if (p2.iccid) document.getElementById('iccidProfile2').value = p2.iccid;
                        if (p2.apn) document.getElementById('apnProfile2').value = p2.apn;
                        if (p2.pdpType) setSelectValue(document.getElementById('apnPDPType2'), p2.pdpType);
                    }
                } else {
                    showNotification('No existing profiles found', true);
                }
            })
            .catch(error => {
                showNotification('Error fetching profiles: ' + error.message, true);
            });
    }

    // Function to validate form
    function validateForm() {
        const iccid1 = document.getElementById('iccidProfile1').value;
        const apn1 = document.getElementById('apnProfile1').value;
        const pdp1 = document.getElementById('apnPDPType1').value;
        
        const iccid2 = document.getElementById('iccidProfile2').value;
        const apn2 = document.getElementById('apnProfile2').value;
        const pdp2 = document.getElementById('apnPDPType2').value;

        // Validate first profile (required)
        if (!iccid1 || !apn1 || pdp1 === 'Select APN PDP Type') {
            showNotification('Please fill in all fields for Profile 1', true);
            return false;
        }

        if (!validateICCID(iccid1)) {
            showNotification('Invalid ICCID format in Profile 1 (should be 19-20 digits)', true);
            return false;
        }
        if (!validateAPN(apn1)) {
            showNotification('Invalid APN format in Profile 1 (alphanumeric, dots, and hyphens only)', true);
            return false;
        }

        // Validate second profile only if any field is filled
        if (iccid2 || apn2 || pdp2 !== 'Select APN PDP Type') {
            if (!validateICCID(iccid2)) {
                showNotification('Invalid ICCID format in Profile 2 (should be 19-20 digits)', true);
                return false;
            }
            if (!validateAPN(apn2)) {
                showNotification('Invalid APN format in Profile 2 (alphanumeric, dots, and hyphens only)', true);
                return false;
            }
            if (pdp2 === 'Select APN PDP Type') {
                showNotification('Please select PDP type for Profile 2', true);
                return false;
            }
        }

        return true;
    }

    // Handle form submission
    document.getElementById('saveAPNProfile').addEventListener('click', function(e) {
        e.preventDefault();

        if (!validateForm()) {
            return;
        }

        const formData = {
            iccidProfile1: document.getElementById('iccidProfile1').value,
            apnProfile1: document.getElementById('apnProfile1').value,
            pdpType1: document.getElementById('apnPDPType1').value,
            iccidProfile2: document.getElementById('iccidProfile2').value || '',
            apnProfile2: document.getElementById('apnProfile2').value || '',
            pdpType2: document.getElementById('apnPDPType2').value || 'IP' // Default value if not selected
        };

        // Send data to the server
        fetch('/cgi-bin/apn-profile.sh', {
            method: 'POST',
            headers: {
                'Content-Type': 'application/x-www-form-urlencoded',
            },
            body: Object.keys(formData).map(key => {
                return encodeURIComponent(key) + '=' + encodeURIComponent(formData[key])
            }).join('&')
        })
        .then(response => response.json())
        .then(data => {
            if (data.status === 'success') {
                showNotification('APN profiles saved successfully');
            } else {
                showNotification(data.message || 'Error saving APN profiles', true);
            }
        })
        .catch(error => {
            showNotification('Error saving APN profiles: ' + error.message, true);
        });
    });

    // Handle reset button
    document.getElementById('resetAPNProfile').addEventListener('click', function(e) {
        e.preventDefault();
        
        document.getElementById('iccidProfile1').value = '';
        document.getElementById('apnProfile1').value = '';
        document.getElementById('apnPDPType1').selectedIndex = 0;
        document.getElementById('iccidProfile2').value = '';
        document.getElementById('apnProfile2').value = '';
        document.getElementById('apnPDPType2').selectedIndex = 0;
        
        showNotification('Form has been reset');
    });

    // Fetch existing profiles when the page loads
    fetchProfiles();
});
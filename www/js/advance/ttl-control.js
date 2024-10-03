// TTL Control functionality
const TTLControl = {
    async getCurrentState() {
        try {
            const response = await fetch('/cgi-bin/ttl.sh');
            const data = await response.json();
            return {
                isEnabled: data.isEnabled,
                currentValue: data.currentValue || 0
            };
        } catch (error) {
            console.error('Error fetching TTL state:', error);
            return { isEnabled: false, currentValue: 0 };
        }
    },

    async setTTLValue(value) {
        try {
            const response = await fetch('/cgi-bin/ttl.sh', {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/x-www-form-urlencoded',
                },
                body: `ttl=${value}`
            });
            const result = await response.json();
            return result.success;
        } catch (error) {
            console.error('Error setting TTL value:', error);
            return false;
        }
    },

    updateUI(isEnabled, value) {
        const stateInput = document.getElementById('ttl-state');
        const valueInput = document.getElementById('ttl-current-value');
        const stateIcon = stateInput.nextElementSibling.querySelector('i');
        const valueIcon = valueInput.nextElementSibling.querySelector('i');
        
        // Update State UI
        if (isEnabled) {
            // Enabled state
            stateInput.value = 'Enabled';
            stateInput.classList.remove('has-text-warning', 'is-danger');
            stateInput.classList.add('has-text-success', 'has-text-weight-bold');
            stateIcon.classList.remove('fa-exclamation-triangle', 'has-text-warning');
            stateIcon.classList.add('fa-check', 'has-text-success');
        } else {
            // Disabled state
            stateInput.value = 'Disabled';
            stateInput.classList.remove('has-text-success', 'is-danger');
            stateInput.classList.add('has-text-warning', 'has-text-weight-bold');
            stateIcon.classList.remove('fa-check', 'has-text-success');
            stateIcon.classList.add('fa-exclamation-triangle', 'has-text-warning');
        }
        
        // Update Value UI
        valueInput.value = value.toString();
        valueInput.classList.add('has-text-weight-bold', 'has-text-white');
        if (isEnabled) {
            valueIcon.classList.remove('fa-exclamation-triangle', 'has-text-warning');
            valueIcon.classList.add('fa-check', 'has-text-success');
        } else {
            valueIcon.classList.remove('fa-check', 'has-text-success');
            valueIcon.classList.add('fa-exclamation-triangle', 'has-text-warning');
        }
    }
};

// Event Listeners
document.addEventListener('DOMContentLoaded', async function() {
    // Initial state fetch
    const { isEnabled, currentValue } = await TTLControl.getCurrentState();
    TTLControl.updateUI(isEnabled, currentValue);
    
    // Submit button event listener
    document.getElementById('ttl-submit').addEventListener('click', async function() {
        const newValue = document.getElementById('ttl-set-value').value;
        const numValue = parseInt(newValue);
        
        if (isNaN(numValue) || numValue < 0) {
            alert('Please enter a valid TTL value (0 or positive number)');
            return;
        }
        
        const success = await TTLControl.setTTLValue(numValue);
        if (success) {
            TTLControl.updateUI(numValue !== 0, numValue);
            alert('TTL settings updated successfully');
        } else {
            alert('Failed to update TTL settings');
        }
    });
});
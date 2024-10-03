document.addEventListener('DOMContentLoaded', function() {
    const modal = document.getElementById('reboot-modal');
    const rebootButton = document.getElementById('rebootModem');
    const cancelButtons = modal.querySelectorAll('.cancel, .modal-background');
    const restartConnectionBtn = document.querySelector('a.button.is-link.is-outlined');
    const modalMessage = document.getElementById('modal-message');
    const loadingContent = document.getElementById('loading-content');
    const modalButtons = document.getElementById('modal-buttons');
    const countdownElement = document.getElementById('countdown');
    
    let countdownInterval;

    function toggleModal(show = true) {
        modal.classList.toggle('is-active', show);
        document.documentElement.classList.toggle('is-clipped', show);
        
        // Reset modal content when closing
        if (!show) {
            modalMessage.style.display = 'block';
            loadingContent.style.display = 'none';
            modalButtons.style.display = 'flex';
            if (countdownInterval) {
                clearInterval(countdownInterval);
            }
            countdownElement.textContent = '80';
        }
    }

    function startCountdown() {
        let timeLeft = 80;
        
        // Update display for countdown
        modalMessage.style.display = 'none';
        loadingContent.style.display = 'flex';
        modalButtons.style.display = 'none';
        
        countdownInterval = setInterval(() => {
            timeLeft--;
            countdownElement.textContent = timeLeft;
            
            if (timeLeft <= 0) {
                clearInterval(countdownInterval);
                window.location.reload();
            }
        }, 1000);
    }

    // Show modal when restart connection button is clicked
    restartConnectionBtn.addEventListener('click', function(e) {
        e.preventDefault();
        toggleModal(true);
    });

    // Hide modal when cancel or background is clicked
    cancelButtons.forEach(button => {
        button.addEventListener('click', () => toggleModal(false));
    });

    // Handle ESC key press
    document.addEventListener('keydown', function(e) {
        if (e.key === 'Escape' && modal.classList.contains('is-active')) {
            toggleModal(false);
        }
    });

    // Function to send AT command
    async function sendRebootCommand() {
        try {
            // Disable the reboot button and show loading state
            rebootButton.classList.add('is-loading');
            rebootButton.disabled = true;

            const response = await fetch('/cgi-bin/atinout_handler.sh', {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/x-www-form-urlencoded',
                },
                body: 'command=' + encodeURIComponent('AT+CFUN=1,1')
            });

            if (!response.ok) {
                throw new Error(`HTTP error! status: ${response.status}`);
            }

            const data = await response.json();
            
            if (data.output && data.output.includes('OK')) {
                startCountdown();
            } else {
                throw new Error('Reboot command failed');
            }

        } catch (error) {
            console.error('Error:', error);
            toggleModal(false);
            showNotification('Failed to reboot device. Please try again.', 'is-danger');
        } finally {
            // Re-enable the reboot button and remove loading state
            rebootButton.classList.remove('is-loading');
            rebootButton.disabled = false;
        }
    }

    // Function to show notification (for errors only now)
    function showNotification(message, type = 'is-info') {
        const notification = document.createElement('div');
        notification.className = `notification ${type} is-light`;
        notification.style.position = 'fixed';
        notification.style.top = '1rem';
        notification.style.right = '1rem';
        notification.style.zIndex = '9999';
        notification.style.maxWidth = '300px';

        const deleteButton = document.createElement('button');
        deleteButton.className = 'delete';
        deleteButton.addEventListener('click', () => notification.remove());
        
        notification.appendChild(deleteButton);
        notification.appendChild(document.createTextNode(message));
        
        document.body.appendChild(notification);

        setTimeout(() => {
            if (document.body.contains(notification)) {
                notification.remove();
            }
        }, 5000);
    }

    // Handle reboot button click
    rebootButton.addEventListener('click', sendRebootCommand);
});
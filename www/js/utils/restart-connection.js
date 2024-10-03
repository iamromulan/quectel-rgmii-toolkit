document.addEventListener('DOMContentLoaded', function() {
    const restartBtn = document.getElementById('restartConnectionBtn');
    
    // Function to send AT commands
    async function sendRestartCommands() {
        try {
            // Disable the restart button and show loading state
            restartBtn.classList.add('is-loading');
            restartBtn.disabled = true;

            // Send AT+CFUN=0
            const response1 = await fetch('/cgi-bin/atinout_handler.sh', {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/x-www-form-urlencoded',
                },
                body: 'command=' + encodeURIComponent('AT+CFUN=0')
            });

            if (!response1.ok) {
                throw new Error(`HTTP error! status: ${response1.status}`);
            }

            // Wait for 2 seconds
            await new Promise(resolve => setTimeout(resolve, 2000));

            // Send AT+CFUN=1
            const response2 = await fetch('/cgi-bin/atinout_handler.sh', {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/x-www-form-urlencoded',
                },
                body: 'command=' + encodeURIComponent('AT+CFUN=1')
            });

            if (!response2.ok) {
                throw new Error(`HTTP error! status: ${response2.status}`);
            }

            const data1 = await response1.json();
            const data2 = await response2.json();
            
            if (data1.output.includes('OK') && data2.output.includes('OK')) {
                alert('Connection restarted successfully');
                // Optionally reload the page after a short delay
                setTimeout(() => {
                    window.location.reload();
                }, 1000);
            } else {
                throw new Error('Restart command failed');
            }

        } catch (error) {
            console.error('Error:', error);
            alert('Failed to restart connection. Please try again.');
        } finally {
            // Re-enable the restart button and remove loading state
            restartBtn.classList.remove('is-loading');
            restartBtn.disabled = false;
        }
    }

    // Add click event listener to the restart button
    if (restartBtn) {
        restartBtn.addEventListener('click', sendRestartCommands);
    } else {
        console.warn('Restart Connection button not found in the DOM');
    }
});
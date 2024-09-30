document.addEventListener('DOMContentLoaded', () => {
    // Function to generate a random token
    function generateAuthToken(length = 32) {
        const charset = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
        let token = '';
        for (let i = 0; i < length; i++) {
            const randomIndex = Math.floor(Math.random() * charset.length);
            token += charset[randomIndex];
        }
        return token;
    }

    // Initially hide the body to prevent content from flashing
    document.body.style.display = 'none';

    // Check if the user is already logged in
    const authToken = localStorage.getItem('authToken');
    
    // Define which pages should be protected
    const protectedPages = [
        '/home.html',
        'advance-settings.html',
        '/bandlock.html',
        '/cell-locking.html',
        '/cell-scanner.html',
        '/cell-settings.html',
        '/cell-sms.html',
        '/about.html',      // Add all the protected HTML pages here
    ];

    const currentPage = window.location.pathname;

    // If the user is not logged in and tries to access a protected page, redirect to login
    if (!authToken && protectedPages.includes(currentPage)) {
        window.location.href = 'index.html';
    } else {
        // Show the page if authentication is successful or not required
        document.body.style.display = '';
    }

    // If the user is logged in and tries to access the login page, redirect to home
    if (authToken && currentPage.includes('index.html')) {
        window.location.href = 'home.html';
    }

    // Login form logic (only for login page)
    const loginForm = document.getElementById('loginForm');
    if (loginForm) {
        loginForm.addEventListener('submit', (e) => {
            e.preventDefault();

            const username = document.getElementById('username').value;
            const password = document.getElementById('password').value;
            const errorElement = document.getElementById('error');

            const validUsername = 'admin'; // Hardcoded credentials for demo purposes
            const validPassword = 'password123';

            // Authenticate user
            if (username === validUsername && password === validPassword) {
                // Generate a random token
                const newToken = generateAuthToken();
                localStorage.setItem('authToken', newToken); // Store the generated token

                // Redirect to home after successful login
                window.location.href = 'home.html';
            } else {
                errorElement.textContent = 'Invalid username or password';
            }
        });
    }

    // Logout button logic (only for pages that have the logout button)
    const logoutButton = document.getElementById('logoutButton');
    if (logoutButton) {
        logoutButton.addEventListener('click', () => {
            localStorage.removeItem('authToken'); // Remove token
            window.location.href = 'index.html';  // Redirect to login
        });
    }

    // Fix for the issue of being redirected to login every time the Home button is clicked
    document.querySelectorAll('.navbar-item').forEach(el => {
        if (el.textContent.includes('Home')) {
            el.addEventListener('click', e => {
                if (localStorage.getItem('authToken')) {
                    e.preventDefault();
                    window.location.href = 'home.html';
                }
            });
        }
    });
});

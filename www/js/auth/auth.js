class AuthManager {
  constructor() {
    this.protectedPages = new Set([
      '/home.html',
      '/advance-settings.html',
      '/bandlock.html',
      '/cell-locking.html',
      '/cell-scanner.html',
      '/cell-settings.html',
      '/cell-sms.html',
      '/about.html'
    ]);
    
    // Session timeout in milliseconds (e.g., 30 minutes)
    this.sessionTimeout = 30 * 60 * 1000;
    
    this.init();
  }

  init() {
    // Initially hide the body to prevent content flashing
    document.body.style.display = 'none';
    
    // Check authentication state
    this.checkAuthState();
    
    // Set up event listeners
    this.setupEventListeners();
    
    // Show body after auth check
    document.body.style.display = '';
  }

  generateAuthToken(length = 32) {
    const charset = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    return Array.from(crypto.getRandomValues(new Uint8Array(length)))
      .map(x => charset[x % charset.length])
      .join('');
  }

  isProtectedPage(path) {
    return this.protectedPages.has(path) || 
           Array.from(this.protectedPages).some(page => path.includes(page));
  }

  getSessionData() {
    const sessionStr = localStorage.getItem('session');
    if (!sessionStr) return null;
    
    try {
      return JSON.parse(sessionStr);
    } catch {
      return null;
    }
  }

  setSessionData(token) {
    const session = {
      token,
      lastActivity: Date.now(),
      expiresAt: Date.now() + this.sessionTimeout
    };
    localStorage.setItem('session', JSON.stringify(session));
  }

  isSessionValid() {
    const session = this.getSessionData();
    if (!session) return false;

    const now = Date.now();
    
    // Check if session has expired
    if (now > session.expiresAt) {
      this.logout();
      return false;
    }

    // Update last activity and extend session if needed
    if (now - session.lastActivity > 5 * 60 * 1000) { // Update every 5 minutes
      this.setSessionData(session.token);
    }

    return true;
  }

  checkAuthState() {
    const currentPath = window.location.pathname;
    const isAuthenticated = this.isSessionValid();

    // Redirect logic
    if (!isAuthenticated && this.isProtectedPage(currentPath)) {
      window.location.href = '/index.html';
      return false;
    }

    if (isAuthenticated && currentPath.includes('index.html')) {
      window.location.href = '/home.html';
      return false;
    }

    return true;
  }

  async login(username, password) {
    try {
      const formData = new URLSearchParams();
      formData.append('username', username);
      formData.append('password', encodeURIComponent(password));

      const response = await fetch('/cgi-bin/auth.sh', {
        method: 'POST',
        body: formData,
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded'
        }
      });

      const result = await response.json();

      if (result.state === 'success') {
        const token = this.generateAuthToken();
        this.setSessionData(token);
        window.location.href = '/home.html';
        return true;
      }
      
      return false;
    } catch (error) {
      console.error('Login error:', error);
      throw new Error('An error occurred during login');
    }
  }

  logout() {
    localStorage.removeItem('session');
    window.location.href = '/index.html';
  }

  setupEventListeners() {
    // Handle login form
    const loginForm = document.getElementById('loginForm');
    if (loginForm) {
      loginForm.addEventListener('submit', async (e) => {
        e.preventDefault();
        const username = document.getElementById('username').value;
        const password = document.getElementById('password').value;
        const errorElement = document.getElementById('error');

        try {
          const success = await this.login(username, password);
          if (!success) {
            errorElement.textContent = 'Invalid username or password';
          }
        } catch (error) {
          errorElement.textContent = error.message;
        }
      });
    }

    // Handle component loading
    window.addEventListener('componentLoaded', (event) => {
      if (event.detail.componentId === 'nav-placeholder') {
        this.setupNavbarHandlers();
      }
    });

    // Set up periodic session check
    setInterval(() => {
      if (this.isProtectedPage(window.location.pathname)) {
        this.isSessionValid();
      }
    }, 60000); // Check every minute
  }

  setupNavbarHandlers() {
    // Handle logout button
    const logoutButton = document.getElementById('logoutButton');
    if (logoutButton) {
      logoutButton.addEventListener('click', (e) => {
        e.preventDefault();
        this.logout();
      });
    }

    // Handle home navigation
    const homeLinks = document.querySelectorAll('.navbar-item');
    homeLinks.forEach(link => {
      if (link.textContent.trim() === 'Home') {
        link.addEventListener('click', (e) => {
          e.preventDefault();
          if (this.isSessionValid()) {
            window.location.href = '/home.html';
          } else {
            window.location.href = '/index.html';
          }
        });
      }
    });
  }
}

// Initialize auth manager when DOM is loaded
document.addEventListener('DOMContentLoaded', () => {
  window.authManager = new AuthManager();
});
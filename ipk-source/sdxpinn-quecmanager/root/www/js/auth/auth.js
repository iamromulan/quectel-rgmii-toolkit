document.addEventListener("DOMContentLoaded", () => {
  const SESSION_DURATION = 30 * 60 * 1000; // 30 minutes in milliseconds
  
  function generateAuthToken(length = 32) {
    const charset = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    return Array.from(crypto.getRandomValues(new Uint8Array(length)))
      .map(x => charset[x % charset.length])
      .join('');
  }
  
  function getSessionData() {
    const sessionStr = localStorage.getItem("session");
    if (!sessionStr) return null;
    
    try {
      return JSON.parse(sessionStr);
    } catch {
      return null;
    }
  }
  
  function setSessionData(token) {
    const session = {
      token,
      lastActivity: Date.now(),
      expiresAt: Date.now() + SESSION_DURATION
    };
    localStorage.setItem("session", JSON.stringify(session));
  }
  
  function isSessionValid() {
    const session = getSessionData();
    if (!session) return false;
    
    const now = Date.now();
    
    // Check if session has expired
    if (now > session.expiresAt) {
      logout();
      return false;
    }
    
    // Extend session if it's been more than 5 minutes since last activity
    if (now - session.lastActivity > 5 * 60 * 1000) {
      setSessionData(session.token);
    }
    
    return true;
  }
  
  function logout() {
    localStorage.removeItem("session");
    window.location.href = "index.html";
  }

  // Initially hide the body to prevent content from flashing
  document.body.style.display = "none";

  // Define which pages should be protected
  const protectedPages = [
    "/home.html",
    "/advance-settings.html",
    "/bandlock.html",
    "/cell-locking.html",
    "/cell-scanner.html",
    "/cell-settings.html",
    "/cell-sms.html",
    "/about.html",
  ];

  const currentPage = window.location.pathname;

  // Authentication check
  const isAuthenticated = isSessionValid();
  
  // Redirect logic
  if (!isAuthenticated && protectedPages.includes(currentPage)) {
    window.location.href = "index.html";
    return;
  }
  
  if (isAuthenticated && currentPage.includes("index.html")) {
    window.location.href = "home.html";
    return;
  }
  
  // Show the page if authentication check is complete
  document.body.style.display = "";

  // Login form logic
  const loginForm = document.getElementById("loginForm");
  if (loginForm) {
    loginForm.addEventListener("submit", async (e) => {
      e.preventDefault();

      const username = document.getElementById("username").value;
      const password = document.getElementById("password").value;
      const errorElement = document.getElementById("error");

      try {
        const formData = new URLSearchParams();
        formData.append("username", username);
        formData.append("password", encodeURIComponent(password));

        const response = await fetch("/cgi-bin/auth.sh", {
          method: "POST",
          body: formData,
          headers: {
            "Content-Type": "application/x-www-form-urlencoded",
          },
        });

        const result = await response.json();

        if (result.state === "success") {
          const newToken = generateAuthToken();
          setSessionData(newToken);
          window.location.href = "home.html";
        } else {
          errorElement.textContent = "Invalid username or password";
        }
      } catch (error) {
        errorElement.textContent = "An error occurred. Please try again later.";
        console.error("Login error:", error);
      }
    });
  }

  // Event listeners
  const logoutButton = document.getElementById("logoutButton");
  if (logoutButton) {
    logoutButton.addEventListener("click", logout);
  }
  
  document.querySelectorAll(".navbar-item").forEach((el) => {
    if (el.textContent.includes("Home")) {
      el.addEventListener("click", (e) => {
        if (isSessionValid()) {
          e.preventDefault();
          window.location.href = "home.html";
        }
      });
    }
  });
  
  // Periodic session check
  if (protectedPages.includes(currentPage)) {
    setInterval(isSessionValid, 60000); // Check every minute
  }
});
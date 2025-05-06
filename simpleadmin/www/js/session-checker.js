// session-checker.js - Add to your JS directory

// Authentication heartbeat checker function
function checkSessionValidity() {
  fetch("/cgi-bin/get_heartbeat?" + new Date().getTime(), {
    method: "GET",
    credentials: "same-origin", // Important: Send cookies with the request
  })
    .then((response) => {
      if (response.status === 403) {
        // Session expired or invalid - redirect to login
        window.location.href = "/login.html";
        return;
      }
      return response.text();
    })
    .then((data) => {
      if (data && data.trim() !== "OK") {
        window.location.href = "/login.html";
      }
    })
    .catch((error) => {
      console.error("Session check failed:", error);
      // Optional: Redirect on network errors
      // window.location.href = '/login.html';
    });
}

// Initialize the session checker
function initSessionChecker(checkIntervalSeconds) {
  // Set a default interval if not specified
  const interval = checkIntervalSeconds || 30;

  // Run the check periodically
  setInterval(checkSessionValidity, interval * 1000);

  // Initial check
  checkSessionValidity();
}

// Auto-initialize with default 30-second interval
document.addEventListener("DOMContentLoaded", function () {
  initSessionChecker(3);
});

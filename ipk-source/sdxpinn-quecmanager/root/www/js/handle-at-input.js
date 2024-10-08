// Handle form submission via JavaScript
document
  .getElementById("commandForm")
  .addEventListener("submit", function (e) {
    e.preventDefault(); // Prevent default form submission

    const commandInput = document.getElementById("command").value;
    const outputTextarea = document.getElementById("output");

    // Make sure input is not empty
    if (commandInput.trim() === "") {
      outputTextarea.value = "Please enter a valid AT command.";
      return;
    }

    // Send the AT command to the CGI script via fetch
    fetch("/cgi-bin/atinout_handler.sh", {
      method: "POST",
      headers: {
        "Content-Type": "application/x-www-form-urlencoded",
      },
      body: `command=${encodeURIComponent(commandInput)}`,
    })
      .then((response) => response.json())
      .then((data) => {
        // Display the response in the textarea
        if (data.output) {
          outputTextarea.value = data.output;
        } else {
          outputTextarea.value = "Error: No output received.";
        }
      })
      .catch((error) => {
        outputTextarea.value = `Error fetching data: ${error.message}`;
      });
  });
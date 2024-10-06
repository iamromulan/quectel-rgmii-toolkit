// toggle-theme.js
document.addEventListener('DOMContentLoaded', function () {
    const themeToggleButton = document.querySelector('.js-theme-toggle');
    const htmlElement = document.documentElement;
    const icon = themeToggleButton.querySelector('.icon i');

    // Toggle theme on button click
    themeToggleButton.addEventListener('click', function () {
        if (htmlElement.classList.contains('theme-dark')) {
            htmlElement.classList.remove('theme-dark');
            htmlElement.classList.add('theme-light');
            localStorage.setItem('theme', 'theme-light');

            // Change icon to moon (light mode)
            icon.classList.remove('fa-sun');
            icon.classList.add('fa-moon');
        } else {
            htmlElement.classList.remove('theme-light');
            htmlElement.classList.add('theme-dark');
            localStorage.setItem('theme', 'theme-dark');

            // Change icon to sun (dark mode)
            icon.classList.remove('fa-moon');
            icon.classList.add('fa-sun');
        }
    });
});

@echo off
setlocal
cd /d "%~dp0"
start "" msedge.exe "https://chromewebstore.google.com/detail/get-cookiestxt-locally/cclelndahbckbenkjhflpdbgdldlbecc"
echo.
echo 1. Allow extensions from other stores if Edge asks.
echo 2. Install Get cookies.txt LOCALLY.
echo 3. Open a logged-in Bilibili page.
echo 4. Export the current site's cookies in Netscape format.
echo 5. Select the exported file in the downloader.
echo.
pause

# Thin layer over dockurr/windows: bakes in the OEM post-install files.
# The Windows ISO is NOT in the image; dockurr downloads it on first run into /storage.
FROM dockurr/windows
COPY oem/ /oem/

const tokenField = document.getElementById("token");
const portField = document.getElementById("port");
const status = document.getElementById("status");

chrome.storage.sync.get({ token: "", port: 41417 }).then((stored) => {
  tokenField.value = stored.token;
  portField.value = stored.port;
});

document.getElementById("save").addEventListener("click", async () => {
  const token = tokenField.value.trim();
  const port = Number(portField.value) || 41417;
  await chrome.storage.sync.set({ token, port });

  status.textContent = "Saved. Checking Aigle…";
  try {
    const response = await fetch(`http://127.0.0.1:${port}/ping`);
    status.textContent = response.ok ? "Connected to Aigle." : "Aigle replied, but not happily.";
  } catch {
    status.textContent = "Aigle isn’t listening — enable the server in its Settings.";
  }
});

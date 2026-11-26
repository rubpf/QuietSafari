document.querySelector("#copy").addEventListener("click", async () => {
  const command = document.querySelector("#brew").textContent;
  const button = document.querySelector("#copy");
  try {
    await navigator.clipboard.writeText(command);
    button.textContent = "Copied";
  } catch (error) {
    button.textContent = "Select the command";
  }
});

const button = document.querySelector("#lang");
const saved = localStorage.getItem("qs-lang");
if (saved === "en") document.body.classList.add("lang-en");

function paint() {
  const english = document.body.classList.contains("lang-en");
  document.documentElement.lang = english ? "en" : "ru";
  button.textContent = english ? "RU" : "EN";
}

button.addEventListener("click", () => {
  document.body.classList.toggle("lang-en");
  localStorage.setItem("qs-lang", document.body.classList.contains("lang-en") ? "en" : "ru");
  paint();
});
paint();

document.querySelector("#copy").addEventListener("click", async () => {
  const command = document.querySelector("#brew").textContent;
  try {
    await navigator.clipboard.writeText(command);
    button.dataset.copied = "1";
    document.querySelector("#copy").textContent = document.body.classList.contains("lang-en") ? "Copied" : "Скопировано";
  } catch (error) {
    document.querySelector("#copy").textContent = command;
  }
});

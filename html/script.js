window.addEventListener("message", function (event) {
  const data = event.data;
  if (data.action === "show") {
    document.body.style.display = "block";
    document.querySelectorAll(".tab-button").forEach(btn => btn.classList.remove("active"));
    document.querySelectorAll(".content").forEach(c => c.classList.add("hidden"));
    const target = data.tab || "main";
    document.querySelector(`.tab-button[data-tab="${target}"]`)?.classList.add("active");
    document.getElementById(target)?.classList.remove("hidden");
  } else if (data.action === "hide") {
    document.body.style.display = "none";
  } else if (data.action === "updateLeaderboard") {
    updateTable("mainBody", data.leaderboard.overall || []);
    updateTable("weeklyBody", data.leaderboard.weekly || []);
    updateTable("dailyBody", data.leaderboard.daily || []);
    updateTable("aiBody", data.leaderboard.ai || []);
  }
});

function updateTable(id, rows) {
  const table = document.getElementById(id);
  table.innerHTML = "";
  rows.forEach(row => {
    const tr = document.createElement("tr");
    tr.innerHTML = `<td>${row.player_name}</td><td>${row.kills}</td><td>${row.deaths}</td>`;
    table.appendChild(tr);
  });
}

document.getElementById("closeBtn").addEventListener("click", () => {
  fetch(`https://${GetParentResourceName()}/close`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({})
  });
});

document.querySelectorAll(".tab-button").forEach(button => {
  button.addEventListener("click", () => {
    document.querySelectorAll(".tab-button").forEach(btn => btn.classList.remove("active"));
    button.classList.add("active");

    const selected = button.dataset.tab;
    document.querySelectorAll(".content").forEach(el => {
      el.classList.toggle("hidden", el.id !== selected);
    });
  });
});

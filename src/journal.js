const themeButton = document.getElementById('themeToggle');
function updateThemeIcon() {
  const dark = document.documentElement.dataset.theme === 'dark';
  themeButton.querySelector('.theme-toggle__icon').textContent = dark ? '🌙' : '☀️';
  themeButton.setAttribute('aria-pressed', String(dark));
}
updateThemeIcon();
themeButton.addEventListener('click', () => {
  const theme = document.documentElement.dataset.theme === 'dark' ? 'light' : 'dark';
  document.documentElement.dataset.theme = theme;
  try { localStorage.setItem('theme', theme); } catch { /* Theme still applies without storage. */ }
  updateThemeIcon();
});

const dialog = document.getElementById('journalImageDialog');
const preview = document.getElementById('journalPreviewImage');
document.querySelectorAll('[data-journal-image]').forEach(button => {
  button.addEventListener('click', () => {
    const image = button.querySelector('img');
    preview.src = image.currentSrc || image.src;
    preview.alt = image.alt;
    preview.classList.toggle('is-portrait', image.naturalHeight > image.naturalWidth);
    document.getElementById('previewTitle').textContent = image.alt;
    dialog.showModal();
    dialog.querySelector('.image-dialog-body').scrollTop = 0;
  });
});
document.getElementById('closeJournalImage').addEventListener('click', () => dialog.close());
dialog.addEventListener('click', event => {
  const rect = dialog.getBoundingClientRect();
  if (event.target === dialog && (event.clientX < rect.left || event.clientX > rect.right || event.clientY < rect.top || event.clientY > rect.bottom)) dialog.close();
});

// Mark the section nearest the reading position, without adding history entries.
const sections = [...document.querySelectorAll('.document-article section[id]')];
const links = [...document.querySelectorAll('.document-toc li a')];
let scheduled = false;
function updateCurrentSection() {
  let current = sections[0];
  for (const section of sections) {
    if (section.getBoundingClientRect().top <= 180) current = section;
  }
  links.forEach(link => {
    if (link.hash === `#${current.id}`) link.setAttribute('aria-current', 'location');
    else link.removeAttribute('aria-current');
  });
  scheduled = false;
}
window.addEventListener('scroll', () => {
  if (!scheduled) { scheduled = true; requestAnimationFrame(updateCurrentSection); }
}, {passive: true});
updateCurrentSection();

// Ask the browser to finish loading figures before opening its PDF/print flow.
document.getElementById('printJournal').addEventListener('click', async () => {
  const button = document.getElementById('printJournal');
  button.disabled = true;
  button.textContent = '正在准备图片…';
  const images = [...document.querySelectorAll('.document-article img')];
  images.forEach(image => { image.loading = 'eager'; });
  await Promise.allSettled(images.map(image => image.decode()));
  button.disabled = false;
  button.textContent = '打印 / 保存为 PDF ↗';
  window.print();
});

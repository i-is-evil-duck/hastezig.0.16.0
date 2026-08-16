(function () {
  'use strict';

  document.addEventListener('DOMContentLoaded', function () {
    if (document.getElementById('paste-form')) return initCreate();
    if (document.getElementById('paste-list')) return initView();
  });

  var LANGS = [
    ['auto', 'Auto detect'],
    ['plaintext', 'Plain text'],
    ['zig', 'Zig'],
    ['javascript', 'JavaScript'],
    ['typescript', 'TypeScript'],
    ['python', 'Python'],
    ['rust', 'Rust'],
    ['go', 'Go'],
    ['c', 'C'],
    ['cpp', 'C++'],
    ['csharp', 'C#'],
    ['java', 'Java'],
    ['json', 'JSON'],
    ['bash', 'Bash / Shell'],
    ['sql', 'SQL'],
    ['yaml', 'YAML'],
    ['markdown', 'Markdown'],
    ['xml', 'HTML / XML'],
    ['css', 'CSS'],
    ['ini', 'INI / Config']
  ];

  function langSelect(selected) {
    var sel = document.createElement('select');
    LANGS.forEach(function (pair) {
      var opt = document.createElement('option');
      opt.value = pair[0];
      opt.textContent = pair[1];
      sel.appendChild(opt);
    });
    sel.value = selected || 'auto';
    return sel;
  }

  function blobEditor(blob) {
    var box = document.createElement('div');
    box.className = 'blob';

    var bar = document.createElement('div');
    bar.className = 'blob-bar';

    var label = document.createElement('span');
    label.className = 'blob-label';
    label.textContent = 'language';
    bar.appendChild(label);

    var sel = langSelect(blob ? blob.lang : 'auto');
    sel.className = 'blob-lang';
    bar.appendChild(sel);

    var remove = document.createElement('button');
    remove.type = 'button';
    remove.className = 'blob-remove';
    remove.textContent = 'remove';
    bar.appendChild(remove);

    box.appendChild(bar);

    var ta = document.createElement('textarea');
    ta.className = 'blob-content';
    ta.placeholder = 'Paste your code here...';
    if (blob) ta.value = blob.content;
    box.appendChild(ta);

    remove.addEventListener('click', function () {
      if (box.parentElement) box.remove();
    });

    return box;
  }

  function collectBlobs(list) {
    var blobs = [];
    var boxes = list.querySelectorAll('.blob');
    for (var i = 0; i < boxes.length; i++) {
      var content = boxes[i].querySelector('.blob-content').value;
      if (!content.trim()) continue;
      var lang = boxes[i].querySelector('.blob-lang').value;
      blobs.push({ content: content, lang: lang });
    }
    return blobs;
  }

  function submitPaste(blobs, error) {
    return fetch('/api/paste', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ blobs: blobs })
    })
      .then(function (res) {
        return res.json().then(function (data) {
          if (!res.ok) throw new Error(data.error || 'Failed to create paste.');
          return data;
        });
      })
      .then(function (data) {
        window.location.href = '/' + data.id;
      })
      .catch(function (err) {
        showError(error, String(err.message || err));
      });
  }

  function initCreate() {
    var form = document.getElementById('paste-form');
    var list = document.getElementById('blob-list');
    var add = document.getElementById('add-blob');
    var error = document.getElementById('error');

    list.appendChild(blobEditor(null));

    add.addEventListener('click', function () {
      list.appendChild(blobEditor(null));
    });

    form.addEventListener('submit', function (event) {
      event.preventDefault();
      error.hidden = true;
      var blobs = collectBlobs(list);
      if (!blobs.length) {
        showError(error, 'Nothing to paste.');
        return;
      }
      submitPaste(blobs, error);
    });
  }

  function lineNumbers(text) {
    var count = text.split('\n').length;
    var buf = [];
    for (var i = 1; i <= count; i++) buf.push(String(i));
    return buf.join('\n');
  }

  function renderBlobBox(blob) {
    var box = document.createElement('div');
    box.className = 'blob';

    var bar = document.createElement('div');
    bar.className = 'blob-bar';

    var label = document.createElement('span');
    label.className = 'blob-label';
    label.textContent = blob.lang === 'auto' ? 'auto' : blob.lang;
    bar.appendChild(label);

    var copy = document.createElement('button');
    copy.type = 'button';
    copy.textContent = 'copy';
    bar.appendChild(copy);
    box.appendChild(bar);

    var body = document.createElement('div');
    body.className = 'blob-body';

    var nums = document.createElement('pre');
    nums.className = 'linenos';
    nums.textContent = lineNumbers(blob.content);

    var pre = document.createElement('pre');
    var code = document.createElement('code');
    highlight(code, blob.content, blob.lang);
    pre.appendChild(code);

    body.appendChild(nums);
    body.appendChild(pre);
    box.appendChild(body);

    copy.addEventListener('click', function () {
      navigator.clipboard.writeText(blob.content).then(function () {
        copy.textContent = 'copied!';
        setTimeout(function () {
          copy.textContent = 'copy';
        }, 1500);
      });
    });

    return box;
  }

  function highlight(codeEl, content, lang) {
    if (window.hljs) {
      var useAuto = !lang || lang === 'auto' || !hljs.getLanguage(lang);
      if (useAuto) {
        codeEl.innerHTML = hljs.highlightAuto(content).value;
      } else {
        codeEl.className = 'language-' + lang;
        codeEl.textContent = content;
        hljs.highlightElement(codeEl);
      }
    } else {
      codeEl.textContent = content;
    }
  }

  function initView() {
    var id = decodeURIComponent(location.pathname.replace(/^\/+|\/+$/g, ''));
    var error = document.getElementById('error');
    var rawLink = document.getElementById('raw-link');
    var editBtn = document.getElementById('edit');
    var addBtn = document.getElementById('add-blob');
    var saveBtn = document.getElementById('save-new');
    var cancelBtn = document.getElementById('cancel-edit');
    rawLink.href = '/raw/' + encodeURIComponent(id);

    var state = { id: id, blobs: [] };

    function setMode(edit) {
      renderView(edit);
      editBtn.hidden = edit;
      addBtn.hidden = !edit;
      saveBtn.hidden = !edit;
      cancelBtn.hidden = !edit;
    }

    function renderView(edit) {
      var list = document.getElementById('paste-list');
      list.innerHTML = '';
      if (edit) {
        state.blobs.forEach(function (b) {
          list.appendChild(blobEditor(b));
        });
        return;
      }
      state.blobs.forEach(function (b) {
        list.appendChild(renderBlobBox(b));
      });
    }

    fetch('/api/paste/' + encodeURIComponent(id))
      .then(function (res) {
        return res.json().then(function (data) {
          if (!res.ok) throw new Error(data.error || 'Paste not found.');
          return data;
        });
      })
      .then(function (data) {
        document.title = 'hastezig/' + id;
        state.blobs = data.blobs && data.blobs.length
          ? data.blobs
          : [{ lang: data.lang || 'plaintext', content: data.content || '' }];
        renderView(false);
      })
      .catch(function (err) {
        showError(error, String(err.message || err));
      });

    editBtn.addEventListener('click', function () {
      if (!state.blobs.length) return;
      error.hidden = true;
      setMode(true);
    });

    addBtn.addEventListener('click', function () {
      document.getElementById('paste-list').appendChild(blobEditor(null));
    });

    saveBtn.addEventListener('click', function () {
      error.hidden = true;
      var blobs = collectBlobs(document.getElementById('paste-list'));
      if (!blobs.length) {
        showError(error, 'Nothing to paste.');
        return;
      }
      submitPaste(blobs, error);
    });

    cancelBtn.addEventListener('click', function () {
      error.hidden = true;
      setMode(false);
    });
  }

  function showError(el, msg) {
    el.textContent = msg;
    el.hidden = false;
  }
})();

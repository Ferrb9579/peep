import fs from 'node:fs';

const appiumUrl = process.env.APPIUM_URL ?? 'http://127.0.0.1:4723';
const packageName = 'com.example.peep';
const runId = process.env.PEEP_TEST_RUN ?? Date.now().toString().slice(-8);
const password = 'PeepTest!2026';
const localSignalingUrl = 'ws://10.0.2.2:8787/ws';
const users = {
  a: `peep_a_${runId}`.toLowerCase(),
  b: `peep_b_${runId}`.toLowerCase(),
};
const artifactDir = process.env.PEEP_TEST_ARTIFACTS ?? `/tmp/peep-appium-${runId}`;
fs.mkdirSync(artifactDir, {recursive: true});

const results = [];

function sleep(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

async function request(path, {method = 'GET', body} = {}) {
  const response = await fetch(`${appiumUrl}${path}`, {
    method,
    headers: body === undefined ? undefined : {'content-type': 'application/json'},
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const payload = await response.json();
  if (!response.ok || payload.value?.error) {
    throw new Error(payload.value?.message ?? `${method} ${path} failed (${response.status})`);
  }
  return payload.value;
}

class Device {
  constructor(name, udid, systemPort) {
    this.name = name;
    this.udid = udid;
    this.systemPort = systemPort;
    this.sessionId = null;
  }

  async start() {
    const value = await request('/session', {
      method: 'POST',
      body: {
        capabilities: {
          alwaysMatch: {
            platformName: 'Android',
            'appium:automationName': 'UiAutomator2',
            'appium:udid': this.udid,
            'appium:deviceName': this.name,
            'appium:appPackage': packageName,
            'appium:appActivity': '.MainActivity',
            'appium:noReset': true,
            'appium:autoGrantPermissions': true,
            'appium:newCommandTimeout': 1800,
            'appium:systemPort': this.systemPort,
          },
        },
      },
    });
    this.sessionId = value.sessionId;
  }

  async stop() {
    if (this.sessionId === null) return;
    try {
      await request(`/session/${this.sessionId}`, {method: 'DELETE'});
    } finally {
      this.sessionId = null;
    }
  }

  get base() {
    if (this.sessionId === null) throw new Error(`${this.name} has no Appium session`);
    return `/session/${this.sessionId}`;
  }

  async source() {
    return request(`${this.base}/source`);
  }

  async find(using, value) {
    const element = await request(`${this.base}/element`, {
      method: 'POST',
      body: {using, value},
    });
    return element['element-6066-11e4-a52e-4f735466cecf'];
  }

  async findA11y(label) {
    return this.find('accessibility id', label);
  }

  async findXpath(xpath) {
    return this.find('xpath', xpath);
  }

  async clickElement(elementId) {
    await request(`${this.base}/element/${elementId}/click`, {
      method: 'POST',
      body: {},
    });
  }

  async clickA11y(label) {
    await this.clickElement(await this.findA11y(label));
  }

  async clickXpath(xpath) {
    await this.clickElement(await this.findXpath(xpath));
  }

  async typeXpath(xpath, text) {
    const element = await this.findXpath(xpath);
    await request(`${this.base}/element/${element}/clear`, {method: 'POST', body: {}});
    await request(`${this.base}/element/${element}/value`, {
      method: 'POST',
      body: {text, value: [...text]},
    });
  }

  async back() {
    await request(`${this.base}/back`, {method: 'POST', body: {}});
  }

  async screenshot(name) {
    const encoded = await request(`${this.base}/screenshot`);
    fs.writeFileSync(`${artifactDir}/${this.name}-${name}.png`, encoded, 'base64');
  }

  async waitForText(text, timeout = 15000) {
    const deadline = Date.now() + timeout;
    let source = '';
    while (Date.now() < deadline) {
      source = await this.source();
      if (source.includes(text)) return source;
      await sleep(350);
    }
    throw new Error(`${this.name} did not show ${JSON.stringify(text)}; source saved for diagnosis`);
  }
}

const a = new Device('device-a', 'emulator-5554', 8201);
const b = new Device('device-b', 'emulator-5556', 8202);

async function test(name, action) {
  const startedAt = Date.now();
  try {
    await action();
    results.push({name, status: 'passed', durationMs: Date.now() - startedAt});
    console.log(`PASS ${name}`);
  } catch (error) {
    results.push({name, status: 'failed', durationMs: Date.now() - startedAt, error: `${error}`});
    console.error(`FAIL ${name}: ${error}`);
    throw error;
  } finally {
    fs.writeFileSync(
      `${artifactDir}/report.json`,
      JSON.stringify({runId, users, results}, null, 2),
    );
  }
}

async function createAccount(device, username) {
  await device.clickA11y('Create account');
  await device.clickXpath('//*[contains(@content-desc, "Connection settings")]');
  await device.typeXpath('(//android.widget.EditText)[4]', localSignalingUrl);
  await device.typeXpath('(//android.widget.EditText)[1]', `${username}@example.test`);
  await device.typeXpath('(//android.widget.EditText)[2]', username);
  await device.typeXpath('(//android.widget.EditText)[3]', password);
  await device.clickA11y('Create my account');
  await device.waitForText(`@${username}`, 20000);
}

async function main() {
  try {
    await Promise.all([a.start(), b.start()]);
    await test('cold launch shows complete sign-in UI on both devices', async () => {
      const sources = await Promise.all([a.source(), b.source()]);
      for (const source of sources) {
        for (const expected of ['Welcome back', 'Username', 'Password', 'Sign in securely']) {
          if (!source.includes(expected)) throw new Error(`missing initial control: ${expected}`);
        }
      }
      await Promise.all([a.screenshot('01-login'), b.screenshot('01-login')]);
    });

    await test('account creation succeeds independently on both devices', async () => {
      await Promise.all([createAccount(a, users.a), createAccount(b, users.b)]);
      await Promise.all([a.screenshot('02-home'), b.screenshot('02-home')]);
    });

    fs.writeFileSync(`${artifactDir}/device-a-home.xml`, await a.source());
    fs.writeFileSync(`${artifactDir}/device-b-home.xml`, await b.source());
    console.log(`ARTIFACTS ${artifactDir}`);
  } finally {
    await Promise.allSettled([a.stop(), b.stop()]);
  }
}

await main();

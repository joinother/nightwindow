'use strict';

const fs = require('node:fs');
const path = require('node:path');

function dayAt(timestamp) {
  return new Date(timestamp + 8 * 3600000).toISOString().slice(0, 10);
}

class UpstreamQuota {
  constructor(filename, { daily = 2000, hourly = 200, minute = 90, now = Date.now } = {}) {
    for (const value of [daily, hourly, minute]) {
      if (!Number.isSafeInteger(value) || value < 1) throw new Error('invalid upstream budget');
    }
    this.filename = filename;
    this.daily = daily;
    this.hourly = hourly;
    this.minute = minute;
    this.now = now;
    this.reason = '';
    try {
      this.state = JSON.parse(fs.readFileSync(filename, 'utf8'));
      if (!this.state || !Number.isSafeInteger(this.state.dayCalls) || this.state.dayCalls < 0 ||
          !Number.isSafeInteger(this.state.monthCalls) || this.state.monthCalls < 0) {
        throw new Error('invalid usage state');
      }
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
      this.state = { day: dayAt(now()), dayCalls: 0, month: dayAt(now()).slice(0, 7), monthCalls: 0,
        timezone: 'Asia/Shanghai', hits: [], blockedUntil: 0 };
    }
    if (this.state.timezone !== 'Asia/Shanghai') {
      this.state.legacyUTC = { day: this.state.day, dayCalls: this.state.dayCalls,
        month: this.state.month, monthCalls: this.state.monthCalls };
      this.state.day = dayAt(now());
      this.state.month = this.state.day.slice(0, 7);
      this.state.transitionDay = this.state.day;
      this.state.timezone = 'Asia/Shanghai';
    }
    this.rollover();
    this.persist();
  }

  rollover() {
    const day = dayAt(this.now());
    const month = day.slice(0, 7);
    const changed = this.state.day !== day || this.state.month !== month;
    if (this.state.day !== day) {
      this.state.day = day;
      this.state.dayCalls = 0;
      this.state.endpoints = {};
    }
    if (this.state.month !== month) {
      this.state.month = month;
      this.state.monthCalls = 0;
    }
    this.state.hits = (this.state.hits || []).filter((value) => Number.isFinite(value) && value > this.now() - 3600000);
    return changed;
  }

  persist() {
    fs.mkdirSync(path.dirname(this.filename), { recursive: true, mode: 0o700 });
    const temporary = this.filename + '.tmp';
    const descriptor = fs.openSync(temporary, 'w', 0o600);
    try {
      fs.writeFileSync(descriptor, JSON.stringify(this.state));
      fs.fsyncSync(descriptor);
    } finally {
      fs.closeSync(descriptor);
    }
    fs.renameSync(temporary, this.filename);
  }

  reserve(endpoint) {
    this.rollover();
    const now = this.now();
    this.reason = this.state.blockedUntil > now ? 'upstream_cooldown' :
      this.state.dayCalls >= this.daily ? 'daily_budget' :
      this.state.hits.length >= this.hourly ? 'hourly_budget' :
      this.state.hits.filter((value) => value > now - 60000).length >= this.minute ? 'minute_budget' : '';
    if (this.reason) return false;
    this.state.dayCalls++;
    this.state.monthCalls++;
    this.state.hits.push(now);
    this.state.endpoints = this.state.endpoints || {};
    this.state.endpoints[endpoint] = (this.state.endpoints[endpoint] || 0) + 1;
    try {
      this.persist();
      return true;
    } catch {
      this.reason = 'budget_storage_unavailable';
      return false;
    }
  }

  backoff(retryAfter) {
    const seconds = Number(retryAfter);
    const until = Number.isFinite(seconds) && seconds > 0 ? this.now() + seconds * 1000 : Date.parse(retryAfter);
    this.state.blockedUntil = Math.max(this.state.blockedUntil || 0, this.now() + 60000,
      Number.isFinite(until) ? Math.min(until, this.now() + 86400000) : this.now() + 300000);
    try { this.persist(); } catch { this.reason = 'budget_storage_unavailable'; }
  }

  snapshot() {
    if (this.rollover()) {
      this.reason = '';
      try { this.persist(); } catch { this.reason = 'budget_storage_unavailable'; }
    }
    return { day: this.state.day, dayCalls: this.state.dayCalls, month: this.state.month,
      monthCalls: this.state.monthCalls, timezone: this.state.timezone, dailyLimit: this.daily,
      hourlyLimit: this.hourly, minuteLimit: this.minute, reason: this.reason,
      blockedUntil: this.state.blockedUntil || 0, transitionDay: this.state.transitionDay || null };
  }
}

module.exports = { UpstreamQuota, dayAt };

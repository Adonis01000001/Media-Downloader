export class OAuthError extends Error {
  constructor(code, message, status = 400) {
    super(message);
    this.name = 'OAuthError';
    this.code = code;
    this.status = status;
  }
}

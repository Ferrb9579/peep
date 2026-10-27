import 'package:flutter/material.dart';

import 'peep_theme.dart';

/// Account presentation owns form state; authentication stays in the controller.
class AccountScreen extends StatefulWidget {
  const AccountScreen({
    super.key,
    required this.signalingController,
    required this.emailController,
    required this.usernameController,
    required this.passwordController,
    required this.busy,
    required this.onCreateAccount,
    required this.onSignIn,
    this.error,
  });
  final TextEditingController signalingController;
  final TextEditingController emailController;
  final TextEditingController usernameController;
  final TextEditingController passwordController;
  final bool busy;
  final VoidCallback onCreateAccount;
  final VoidCallback onSignIn;
  final String? error;
  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  final _formKey = GlobalKey<FormState>();
  bool _createAccount = false;
  bool _showPassword = false;

  void _submit() {
    if (widget.busy || !_formKey.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    (_createAccount ? widget.onCreateAccount : widget.onSignIn)();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final wide = constraints.maxWidth >= 860;
      final form = Padding(
        padding: EdgeInsets.all(wide ? 44 : 24),
        child: AutofillGroup(
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!wide) ...[const PeepBrand(), const SizedBox(height: 36)],
                Text(
                  _createAccount
                      ? 'A little closer.\nA lot more private.'
                      : 'Welcome back.',
                  style: Theme.of(context).textTheme.headlineLarge,
                ),
                const SizedBox(height: 12),
                Text(
                  _createAccount
                      ? 'Create your account and find your people.'
                      : 'Good conversations start here.\nSign in to pick up where you left off.',
                  style: const TextStyle(color: PeepColors.muted, height: 1.6),
                ),
                const SizedBox(height: 28),
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: false, label: Text('Sign in')),
                    ButtonSegment(value: true, label: Text('Create account')),
                  ],
                  selected: {_createAccount},
                  showSelectedIcon: false,
                  style: SegmentedButton.styleFrom(
                    selectedBackgroundColor: PeepColors.primarySoft,
                    selectedForegroundColor: PeepColors.primary,
                    side: const BorderSide(color: PeepColors.border),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  onSelectionChanged: widget.busy
                      ? null
                      : (value) => setState(() {
                          _createAccount = value.first;
                          _formKey.currentState?.reset();
                        }),
                ),
                const SizedBox(height: 28),
                if (_createAccount) ...[
                  TextFormField(
                    controller: widget.emailController,
                    enabled: !widget.busy,
                    keyboardType: TextInputType.emailAddress,
                    textInputAction: TextInputAction.next,
                    autofillHints: const [AutofillHints.email],
                    validator: (value) =>
                        value == null ||
                            !RegExp(
                              r'^[^\s@]+@[^\s@]+\.[^\s@]+$',
                            ).hasMatch(value.trim())
                        ? 'Enter a valid email address.'
                        : null,
                    decoration: const InputDecoration(
                      labelText: 'Email address',
                      prefixIcon: Icon(Icons.mail_outline_rounded),
                    ),
                  ),
                  const SizedBox(height: 18),
                ],
                TextFormField(
                  controller: widget.usernameController,
                  enabled: !widget.busy,
                  autocorrect: false,
                  textInputAction: TextInputAction.next,
                  autofillHints: const [AutofillHints.username],
                  validator: (value) =>
                      value == null ||
                          !RegExp(
                            r'^[a-zA-Z0-9_-]{3,32}$',
                          ).hasMatch(value.trim())
                      ? 'Use 3–32 letters, numbers, underscores or hyphens.'
                      : null,
                  decoration: const InputDecoration(
                    labelText: 'Username',
                    prefixIcon: Icon(Icons.alternate_email_rounded),
                  ),
                ),
                const SizedBox(height: 18),
                TextFormField(
                  controller: widget.passwordController,
                  enabled: !widget.busy,
                  obscureText: !_showPassword,
                  autocorrect: false,
                  enableSuggestions: false,
                  textInputAction: TextInputAction.done,
                  onFieldSubmitted: (_) => _submit(),
                  autofillHints: [
                    _createAccount
                        ? AutofillHints.newPassword
                        : AutofillHints.password,
                  ],
                  validator: (value) => value == null || value.isEmpty
                      ? 'Enter your password.'
                      : _createAccount && value.length < 8
                      ? 'Use at least 8 characters.'
                      : null,
                  decoration: InputDecoration(
                    labelText: 'Password',
                    helperText: _createAccount ? 'At least 8 characters' : null,
                    prefixIcon: const Icon(Icons.lock_outline_rounded),
                    suffixIcon: IconButton(
                      tooltip: _showPassword
                          ? 'Hide password'
                          : 'Show password',
                      onPressed: () =>
                          setState(() => _showPassword = !_showPassword),
                      icon: Icon(
                        _showPassword
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined,
                      ),
                    ),
                  ),
                ),
                if (widget.error != null) ...[
                  const SizedBox(height: 18),
                  Semantics(
                    liveRegion: true,
                    child: Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: PeepColors.danger.withValues(alpha: .07),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        widget.error!,
                        style: const TextStyle(color: PeepColors.danger),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: widget.busy ? null : _submit,
                  child: widget.busy
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Flexible(
                              child: Text(
                                _createAccount
                                    ? 'Create my account'
                                    : 'Sign in securely',
                                textAlign: TextAlign.center,
                              ),
                            ),
                            const SizedBox(width: 10),
                            const Icon(Icons.arrow_forward_rounded, size: 18),
                          ],
                        ),
                ),
                const SizedBox(height: 18),
                const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.lock_outline, size: 14, color: PeepColors.muted),
                    SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        'Private by design. Connected by you.',
                        style: TextStyle(fontSize: 12, color: PeepColors.muted),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  shape: const Border(),
                  collapsedShape: const Border(),
                  title: const Text(
                    'Connection settings',
                    style: TextStyle(fontSize: 12, color: PeepColors.muted),
                  ),
                  children: [
                    TextFormField(
                      controller: widget.signalingController,
                      enabled: !widget.busy,
                      keyboardType: TextInputType.url,
                      decoration: const InputDecoration(
                        labelText: 'Signaling server URL',
                      ),
                      validator: (value) {
                        final uri = Uri.tryParse(value?.trim() ?? '');
                        return uri == null ||
                                !['ws', 'wss'].contains(uri.scheme) ||
                                uri.host.isEmpty
                            ? 'Enter a ws:// or wss:// server address.'
                            : null;
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
      return Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(32),
          border: Border.all(color: PeepColors.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: wide
            ? Row(
                children: [
                  const Expanded(child: _WelcomePanel()),
                  Expanded(child: form),
                ],
              )
            : form,
      );
    },
  );
}

class _WelcomePanel extends StatelessWidget {
  const _WelcomePanel();
  @override
  Widget build(BuildContext context) => Container(
    constraints: const BoxConstraints(minHeight: 700),
    padding: const EdgeInsets.all(48),
    decoration: const BoxDecoration(color: PeepColors.navy),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const PeepBrand(light: true),
        const SizedBox(height: 66),
        const Text(
          'Less noise.\nMore connection.',
          style: TextStyle(
            color: Colors.white,
            fontSize: 46,
            height: 1.12,
            letterSpacing: -1.8,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 22),
        const Text(
          'A quiet space for your people.\nMessages, calls, and moments that matter.',
          style: TextStyle(color: Color(0xffb9c9cb), fontSize: 16, height: 1.7),
        ),
        const SizedBox(height: 44),
        Transform.rotate(
          angle: -.035,
          child: Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: const Color(0xff24434a),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: const Color(0xff39565c)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    PeepAvatar(label: 'Your people', radius: 20),
                    SizedBox(width: 12),
                    Text(
                      'The everyday, shared.',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 22),
                const _WelcomeBubble(
                  text: 'Made it home. Talk soon?',
                  local: false,
                ),
                const SizedBox(height: 10),
                const Align(
                  alignment: Alignment.centerRight,
                  child: _WelcomeBubble(
                    text: 'Always. See you in a peep.',
                    local: true,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 48),
        const Row(
          children: [
            Icon(Icons.lock_outline_rounded, color: PeepColors.mint, size: 16),
            SizedBox(width: 8),
            Flexible(
              child: Text(
                'Your messages stay between you.',
                style: TextStyle(color: PeepColors.mint, fontSize: 13),
              ),
            ),
          ],
        ),
      ],
    ),
  );
}

class _WelcomeBubble extends StatelessWidget {
  const _WelcomeBubble({required this.text, required this.local});
  final String text;
  final bool local;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    decoration: BoxDecoration(
      color: local ? PeepColors.mint : const Color(0xff34545b),
      borderRadius: BorderRadius.circular(14),
    ),
    child: Text(
      text,
      style: TextStyle(
        color: local ? PeepColors.navy : Colors.white,
        fontSize: 13,
      ),
    ),
  );
}

// Worker authentication (PRD §7.1, §28 FR-01/FR-02, §32.5 step 1).
//
// PRD §7.1 describes provisioning by a supervisor and §32.5 requires the worker
// to log in WITHOUT internet. So the credential is verified entirely on the
// device against the local worker table, and the passcode is stored only as a
// per-worker salted hash.
//
// A device with no provisioned worker would be unusable, which in the field
// means a dead tablet. So instead of failing, this screen offers first-run
// provisioning and says plainly that it is a device setup step — it does not
// pretend to authenticate against a server that is not there.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/safety.dart';
import '../../app/strings.dart';
import '../widgets/common.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _workerId = TextEditingController();
  final _passcode = TextEditingController();
  final _name = TextEditingController();

  bool _loading = true;
  int _workerCount = 0;
  String? _error;
  String _role = 'asha';

  @override
  void initState() {
    super.initState();
    _loadWorkerCount();
  }

  Future<void> _loadWorkerCount() async {
    try {
      final repos = await ref.read(repositoriesProvider.future);
      final count = await repos.workers.count();
      if (!mounted) return;
      setState(() {
        _workerCount = count;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '$error';
        _loading = false;
      });
    }
  }

  @override
  void dispose() {
    _workerId.dispose();
    _passcode.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    final id = _workerId.text.trim();
    final pass = _passcode.text;

    if (id.isEmpty || pass.isEmpty) {
      setState(() => _error = context.s('login.error.empty'));
      return;
    }

    setState(() => _error = null);
    final repos = await ref.read(repositoriesProvider.future);
    final result = await repos.workers.authenticate(workerId: id, passcode: pass);
    if (!mounted) return;

    if (!result.success) {
      setState(() => _error = result.error == null
          ? context.s('login.error.invalid')
          : context.s(result.error!));
      return;
    }

    // Cleared only once the passcode has actually been used. Clearing it before
    // a sign-in attempt is how the first-run path used to fail: provisioning
    // wiped the field and then called _signIn, which reported "Enter your Worker
    // ID and passcode" to a worker who had just typed one.
    _passcode.clear();
    ref.read(authProvider.notifier).signIn(result.worker!);
    if (mounted) context.go('/home');
  }

  Future<void> _provisionDevice() async {
    final id = _workerId.text.trim();
    final name = _name.text.trim();
    final pass = _passcode.text;

    if (id.isEmpty || name.isEmpty || pass.length < 4) {
      setState(() => _error =
          'Enter a worker ID, a name, and a passcode of at least 4 characters.');
      return;
    }

    setState(() => _error = null);
    final repos = await ref.read(repositoriesProvider.future);
    await repos.workers.provision(
      workerId: id,
      displayName: name,
      role: _role,
      passcode: pass,
      // Recorded so the audit trail can show which device an action came from
      // without needing a server (PRD §25.1).
      credentialMeta: {'provisioned_on_device': true},
    );
    if (!mounted) return;

    setState(() => _workerCount = 1);
    await _signIn();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.strings;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const _BrandHeader(),
                  const SizedBox(height: 28),
                  if (_loading)
                    const LoadingView()
                  else if (_workerCount == 0)
                    _buildProvisioning(s)
                  else
                    _buildLogin(s),
                  const SizedBox(height: 24),
                  const SafetyBanner(dense: true),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLogin(AppStrings s) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(s.t('login.title'), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
        const SizedBox(height: 16),
        TextField(
          controller: _workerId,
          decoration: InputDecoration(
            labelText: s.t('login.worker_id'),
            border: const OutlineInputBorder(),
            prefixIcon: const Icon(Icons.badge_outlined),
          ),
          autocorrect: false,
          textInputAction: TextInputAction.next,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _passcode,
          obscureText: true,
          decoration: InputDecoration(
            labelText: s.t('login.passcode'),
            border: const OutlineInputBorder(),
            prefixIcon: const Icon(Icons.lock_outline),
          ),
          onSubmitted: (_) => _signIn(),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          MessageCard(message: _error!, severity: MessageSeverity.error),
        ],
        const SizedBox(height: 18),
        FilledButton(onPressed: _signIn, child: Text(s.t('login.submit'))),
        const SizedBox(height: 12),
        MessageCard(message: s.t('login.offline_notice')),
      ],
    );
  }

  Widget _buildProvisioning(AppStrings s) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MessageCard(
          title: 'Set up this device',
          message: 'No worker is provisioned on this device yet. In deployment a '
              'supervisor does this once; after that, sign-in works with no '
              'internet.',
          severity: MessageSeverity.warning,
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _name,
          decoration: const InputDecoration(
            labelText: 'Worker name',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.person_outline),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _workerId,
          decoration: const InputDecoration(
            labelText: 'Worker ID',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.badge_outlined),
          ),
          autocorrect: false,
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          initialValue: _role,
          decoration: const InputDecoration(
            labelText: 'Role',
            border: OutlineInputBorder(),
          ),
          items: const [
            DropdownMenuItem(value: 'asha', child: Text('ASHA')),
            DropdownMenuItem(value: 'anm', child: Text('ANM')),
            DropdownMenuItem(value: 'nurse', child: Text('Nurse')),
            DropdownMenuItem(value: 'doctor', child: Text('Doctor')),
          ],
          onChanged: (value) => setState(() => _role = value ?? 'asha'),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _passcode,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: 'Passcode',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.lock_outline),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          MessageCard(message: _error!, severity: MessageSeverity.error),
        ],
        const SizedBox(height: 18),
        FilledButton(
          onPressed: _provisionDevice,
          child: const Text('Provision and sign in'),
        ),
      ],
    );
  }
}

class _BrandHeader extends StatelessWidget {
  const _BrandHeader();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: scheme.primaryContainer,
            shape: BoxShape.circle,
          ),
          child: Icon(Icons.health_and_safety_outlined, size: 40, color: scheme.onPrimaryContainer),
        ),
        const SizedBox(height: 14),
        Text(
          context.s('app.title'),
          style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800),
        ),
        Text(
          context.s('app.tagline'),
          style: TextStyle(fontSize: 14, color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

const express = require('express');
const router = express.Router();
const authController = require('../controllers/authControllers');
const { authMiddleware } = require('../../shared/authMiddleware');

// Public routes
router.post('/register', authController.register);
router.post('/login', authController.login);
router.post('/forgot-password', authController.forgotPassword);
router.post('/reset-password', authController.resetPassword);

// Protected routes (require authentication)
router.get('/profile', authMiddleware, authController.getProfile);
router.put('/profile', authMiddleware, authController.updateProfile);
router.delete('/account', authMiddleware, authController.deleteAccount);

// Inter-service validation (called by other services, not by frontend)
router.get('/validate/:userId', async (req, res) => {
  try {
    const db = require('../db');
    const { rows } = await db.query(
      'SELECT id, email, name FROM users WHERE id = $1',
      [req.params.userId]
    );
    if (rows.length === 0) {
      return res.status(404).json({ valid: false, message: 'User not found' });
    }
    res.json({ valid: true, user: rows[0] });
  } catch (error) {
    res.status(500).json({ valid: false, message: 'Validation failed' });
  }
});

module.exports = router;

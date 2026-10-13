import React, { createContext, useContext, useEffect, useState } from 'react';
import { User, GoogleAuthProvider, signInWithPopup, signOut as fbSignOut, onAuthStateChanged } from 'firebase/auth';
import { doc, getDoc, setDoc } from 'firebase/firestore';
import { auth, db, handleFirestoreError } from '../firebase';
import { OperationType, UserProfile } from '../types';

export const AUTHORIZED_OWNER_EMAIL = 'erickfeliz2026startup@gmail.com';

interface AuthContextType {
  user: User | null;
  userProfile: UserProfile | null;
  loading: boolean;
  isOwner: boolean;
  signInWithGoogle: () => Promise<void>;
  signOut: () => Promise<void>;
  authError: string | null;
}

const AuthContext = createContext<AuthContextType>({
  user: null,
  userProfile: null,
  loading: true,
  isOwner: false,
  signInWithGoogle: async () => {},
  signOut: async () => {},
  authError: null,
});

export const AuthProvider: React.FC<{ children: React.ReactNode }> = ({ children }) => {
  const [user, setUser] = useState<User | null>(null);
  const [userProfile, setUserProfile] = useState<UserProfile | null>(null);
  const [loading, setLoading] = useState(true);
  const [authError, setAuthError] = useState<string | null>(null);

  useEffect(() => {
    const unsubscribe = onAuthStateChanged(auth, async (currentUser) => {
      setUser(currentUser);
      setAuthError(null);

      if (currentUser) {
        // Verify owner authorization
        const isAuthorizedEmail = currentUser.email?.toLowerCase() === AUTHORIZED_OWNER_EMAIL.toLowerCase();

        if (isAuthorizedEmail) {
          try {
            const userDocRef = doc(db, 'users', currentUser.uid);
            const userSnap = await getDoc(userDocRef);

            if (userSnap.exists()) {
              setUserProfile(userSnap.data() as UserProfile);
            } else {
              // Create the initial verified owner record in Firestore
              const newProfile: UserProfile = {
                uid: currentUser.uid,
                email: currentUser.email || AUTHORIZED_OWNER_EMAIL,
                role: 'owner',
                createdAt: new Date().toISOString(),
              };
              await setDoc(userDocRef, newProfile);
              setUserProfile(newProfile);
            }
          } catch (err: any) {
            console.error('Error fetching or initializing user document:', err);
            // Even if offline or error, we preserve basic profile if email matches
            setUserProfile({
              uid: currentUser.uid,
              email: currentUser.email || AUTHORIZED_OWNER_EMAIL,
              role: 'owner',
              createdAt: new Date().toISOString(),
            });
          }
        } else {
          setUserProfile(null);
          setAuthError(`La cuenta ${currentUser.email} no está autorizada. Este sistema es exclusivo para el propietario de Control de Alquileres.`);
        }
      } else {
        setUserProfile(null);
      }
      setLoading(false);
    });

    return () => unsubscribe();
  }, []);

  const signInWithGoogle = async () => {
    try {
      setLoading(true);
      setAuthError(null);
      const provider = new GoogleAuthProvider();
      provider.setCustomParameters({ prompt: 'select_account' });
      await signInWithPopup(auth, provider);
    } catch (err: any) {
      console.error('Sign-in error:', err);
      setAuthError(err.message || 'Error al iniciar sesión con Google.');
      setLoading(false);
    }
  };

  const signOut = async () => {
    try {
      await fbSignOut(auth);
      setUser(null);
      setUserProfile(null);
    } catch (err: any) {
      console.error('Sign-out error:', err);
    }
  };

  const isOwner = Boolean(
    user && (user.email?.toLowerCase() === AUTHORIZED_OWNER_EMAIL.toLowerCase() || userProfile?.role === 'owner')
  );

  return (
    <AuthContext.Provider
      value={{
        user,
        userProfile,
        loading,
        isOwner,
        signInWithGoogle,
        signOut,
        authError,
      }}
    >
      {children}
    </AuthContext.Provider>
  );
};

export const useAuth = () => useContext(AuthContext);
